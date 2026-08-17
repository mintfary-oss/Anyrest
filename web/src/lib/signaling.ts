// Anyrest Signaling Client
// Manages the WebSocket connection to the signaling server and provides
// a typed event emitter for the rest of the app.

import type {
  SignalMessage,
  MessageType,
  RegisterAckPayload,
} from './protocol';

type Handler = (msg: SignalMessage) => void;

export class SignalingClient extends EventTarget {
  private ws: WebSocket | null = null;
  private handlers = new Map<MessageType, Set<Handler>>();
  private reconnectDelay = 1000;
  private closed = false;

  /** Peer ID assigned by the server after registration. */
  peerId: string | null = null;
  /** Relay server address provided during registration. */
  relayAddr: string | null = null;

  constructor(private readonly serverUrl: string) {
    super();
  }

  // ── Connection lifecycle ────────────────────────────────────────────────

  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.closed = false;
      const ws = new WebSocket(this.serverUrl);
      this.ws = ws;

      ws.onopen = () => {
        this.reconnectDelay = 1000;
        this.dispatchEvent(new CustomEvent('open'));
        resolve();
      };

      ws.onerror = (ev) => {
        reject(new Error(`WebSocket error: ${(ev as ErrorEvent).message ?? 'unknown'}`));
      };

      ws.onclose = () => {
        this.dispatchEvent(new CustomEvent('close'));
        if (!this.closed) {
          setTimeout(() => this.reconnect(), this.reconnectDelay);
          this.reconnectDelay = Math.min(this.reconnectDelay * 2, 30_000);
        }
      };

      ws.onmessage = (ev: MessageEvent<string>) => {
        try {
          const msg = JSON.parse(ev.data) as SignalMessage;
          this.route(msg);
        } catch {
          console.warn('[signal] unparseable message', ev.data);
        }
      };
    });
  }

  /** Re-registers after a reconnection. */
  private async reconnect(): Promise<void> {
    try {
      await this.connect();
      if (this.peerId) {
        // Re-register so we keep the same logical session
        this.send({ type: 'register', payload: {} });
      }
    } catch {
      // will retry via onclose
    }
  }

  disconnect(): void {
    this.closed = true;
    this.ws?.close();
    this.ws = null;
  }

  // ── Message I/O ─────────────────────────────────────────────────────────

  send(msg: SignalMessage): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    } else {
      console.warn('[signal] tried to send while not connected', msg.type);
    }
  }

  /** Register this browser as a viewer peer. */
  register(): void {
    this.send({ type: 'register', payload: {} });
  }

  /** Request a connection to a remote agent by its 9-digit peer ID. */
  connectTo(targetId: string): void {
    this.send({
      type: 'connect',
      payload: { target_id: targetId },
    });
  }

  // ── Typed event subscription ─────────────────────────────────────────────

  on(type: MessageType, handler: Handler): void {
    if (!this.handlers.has(type)) this.handlers.set(type, new Set());
    this.handlers.get(type)!.add(handler);
  }

  off(type: MessageType, handler: Handler): void {
    this.handlers.get(type)?.delete(handler);
  }

  private route(msg: SignalMessage): void {
    // Handle bookkeeping internally
    if (msg.type === 'register_ack') {
      const pl = msg.payload as RegisterAckPayload;
      this.peerId = pl.peer_id;
      this.relayAddr = pl.relay_addr;
      this.dispatchEvent(new CustomEvent('registered', { detail: pl }));
    }
    if (msg.type === 'ping') {
      this.send({ type: 'pong' });
      return;
    }
    // Notify type-specific listeners
    this.handlers.get(msg.type)?.forEach((h) => h(msg));
  }
}
