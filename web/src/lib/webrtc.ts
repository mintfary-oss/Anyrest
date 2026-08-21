// Anyrest WebRTC Viewer
// Manages the RTCPeerConnection lifecycle for the browser-based viewer.
// Receives JPEG screen frames over a "frames" data channel and forwards
// keyboard/mouse events over an "input" data channel.

import type { SignalingClient } from './signaling';
import type {
  SDPPayload,
  ICECandidatePayload,
  InputEvent,
} from './protocol';

export type ViewerState =
  | 'idle'
  | 'connecting'
  | 'connected'
  | 'failed'
  | 'disconnected';

export type StateChangeHandler = (state: ViewerState) => void;
/** Called with each decoded JPEG frame as a Blob URL (revoke after use). */
export type FrameHandler = (blobUrl: string) => void;
/** Called every second with fresh connection diagnostics. */
export type StatsHandler = (stats: DiagStats) => void;

const FRAME_MAGIC = 0xa2e501f2;
const HEADER_SIZE = 12; // magic(4) + width(2) + height(2) + seq(4)

// Multiple STUN servers for reliability.
// Google STUN may be blocked or unreliable in Russia — alternatives included.
const ICE_SERVERS: RTCIceServer[] = [
  { urls: 'stun:stun.l.google.com:19302' },
  { urls: 'stun:stun1.l.google.com:19302' },
  { urls: 'stun:stun.stunprotocol.org:3478' },
  { urls: 'stun:stun.ekiga.net:3478' },
  { urls: 'stun:stun.ideasip.com:3478' },
];

/** Live diagnostics data exposed to the UI. */
export interface DiagStats {
  /** WebRTC PeerConnectionState */
  pcState: RTCPeerConnectionState | 'none';
  /** ICE connection state */
  iceState: RTCIceConnectionState | 'none';
  /** Data channel state (frames channel) */
  dcState: RTCDataChannelState | 'none';
  /** ICE candidate type of the active pair: 'host' (LAN/direct), 'srflx' (STUN), 'relay' (TURN) */
  candidateType: 'host' | 'srflx' | 'relay' | 'unknown';
  /** Round-trip time in milliseconds (-1 = unknown) */
  rttMs: number;
  /** Frames received per second */
  fps: number;
  /** Total bytes received over the data channel */
  bytesReceived: number;
  /** Bandwidth in KB/s */
  bandwidthKBps: number;
  /** Remote peer ID */
  remotePeerId: string;
  /** Signaling server URL */
  signalUrl: string;
  /** Connection description */
  connectionType: string;
}

const emptyStats = (remotePeerId = '', signalUrl = ''): DiagStats => ({
  pcState: 'none',
  iceState: 'none',
  dcState: 'none',
  candidateType: 'unknown',
  rttMs: -1,
  fps: 0,
  bytesReceived: 0,
  bandwidthKBps: 0,
  remotePeerId,
  signalUrl,
  connectionType: 'Нет подключения',
});

export class WebRTCViewer {
  private pc: RTCPeerConnection | null = null;
  private inputDC: RTCDataChannel | null = null;
  private framesDC: RTCDataChannel | null = null;
  private remotePeerId: string | null = null;

  // Stats tracking
  private frameCount = 0;
  private lastFrameCount = 0;
  private bytesReceived = 0;
  private lastBytesReceived = 0;
  private statsInterval: ReturnType<typeof setInterval> | null = null;
  private latestStats: DiagStats;
  private signalUrl: string;

  constructor(
    private readonly signaling: SignalingClient,
    private readonly onStateChange: StateChangeHandler,
    private readonly onFrame: FrameHandler,
    private readonly onStats?: StatsHandler,
    signalUrl = '',
  ) {
    this.signalUrl = signalUrl;
    this.latestStats = emptyStats('', signalUrl);
    this.bindSignalingHandlers();
  }

  // ── Public API ────────────────────────────────────────────────────────────

  async startSession(remotePeerId: string): Promise<void> {
    this.remotePeerId = remotePeerId;
    this.latestStats = emptyStats(remotePeerId, this.signalUrl);
    this.onStateChange('connecting');
    this.signaling.connectTo(remotePeerId);
    // Waits for 'offer' from the agent
  }

  sendInput(event: InputEvent): void {
    if (this.inputDC?.readyState === 'open') {
      this.inputDC.send(JSON.stringify(event));
    }
  }

  getStats(): DiagStats {
    return { ...this.latestStats };
  }

  close(): void {
    this.signaling.send({
      type: 'disconnect',
      to: this.remotePeerId ?? undefined,
    });
    this.cleanup();
    this.onStateChange('disconnected');
  }

  // ── Signaling handlers ─────────────────────────────────────────────────

  private bindSignalingHandlers(): void {
    // Agent sends offer → we answer
    this.signaling.on('offer', (msg) => {
      const pl = msg.payload as SDPPayload;
      void this.handleOffer(msg.from!, pl);
    });

    this.signaling.on('ice_candidate', (msg) => {
      const pl = msg.payload as ICECandidatePayload;
      if (this.pc && pl.candidate) {
        void this.pc.addIceCandidate(new RTCIceCandidate(pl));
      }
    });

    this.signaling.on('disconnect', () => {
      this.cleanup();
      this.onStateChange('disconnected');
    });

    this.signaling.on('error', (msg) => {
      console.error('[webrtc] signaling error', msg.payload);
      this.onStateChange('failed');
    });
  }

  // ── WebRTC internals ──────────────────────────────────────────────────

  private async handleOffer(fromId: string, pl: SDPPayload): Promise<void> {
    this.remotePeerId = fromId;
    this.cleanup();

    const pc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
    this.pc = pc;

    // ICE trickle
    pc.onicecandidate = ({ candidate }) => {
      if (candidate) {
        this.signaling.send({
          type: 'ice_candidate',
          to: fromId,
          payload: {
            candidate: candidate.candidate,
            sdpMid: candidate.sdpMid ?? '',
            sdpMLineIndex: candidate.sdpMLineIndex ?? 0,
            usernameFragment: candidate.usernameFragment ?? undefined,
          } satisfies ICECandidatePayload,
        });
      }
    };

    pc.onconnectionstatechange = () => {
      switch (pc.connectionState) {
        case 'connected':
          this.onStateChange('connected');
          this.startStatsPolling();
          break;
        case 'disconnected':
        case 'closed':
          this.cleanup();
          this.onStateChange('disconnected');
          break;
        case 'failed':
          this.onStateChange('failed');
          break;
      }
    };

    // Handle incoming data channels from the agent
    pc.ondatachannel = (ev) => {
      if (ev.channel.label === 'frames') {
        this.framesDC = ev.channel;
        ev.channel.binaryType = 'arraybuffer';
        ev.channel.onmessage = (e: MessageEvent<ArrayBuffer>) => {
          this.decodeFrame(e.data);
        };
      }

      if (ev.channel.label === 'input') {
        // Agent opened an input channel — keep a ref so we can send
        this.inputDC = ev.channel;
      }
    };

    // Open our own input data channel if the agent didn't
    const inputDC = pc.createDataChannel('input', { ordered: true });
    this.inputDC = inputDC;

    await pc.setRemoteDescription(
      new RTCSessionDescription({ type: 'offer', sdp: pl.sdp }),
    );
    const answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    this.signaling.send({
      type: 'answer',
      to: fromId,
      payload: { type: 'answer', sdp: answer.sdp! } satisfies SDPPayload,
    });
  }

  /** Parses the binary frame header and delivers the JPEG as a Blob URL. */
  private decodeFrame(buf: ArrayBuffer): void {
    if (buf.byteLength < HEADER_SIZE) return;

    const view = new DataView(buf);
    const magic = view.getUint32(0, true);
    if (magic !== FRAME_MAGIC) return;

    this.frameCount++;
    this.bytesReceived += buf.byteLength;

    // Payload starts after the 12-byte header
    const jpeg = buf.slice(HEADER_SIZE);
    const blob = new Blob([jpeg], { type: 'image/jpeg' });
    const url = URL.createObjectURL(blob);
    this.onFrame(url);
  }

  // ── Stats polling ─────────────────────────────────────────────────────

  private startStatsPolling(): void {
    if (this.statsInterval) return;
    this.lastFrameCount = this.frameCount;
    this.lastBytesReceived = this.bytesReceived;

    this.statsInterval = setInterval(() => {
      void this.refreshStats();
    }, 1000);
  }

  private stopStatsPolling(): void {
    if (this.statsInterval) {
      clearInterval(this.statsInterval);
      this.statsInterval = null;
    }
  }

  private async refreshStats(): Promise<void> {
    const pc = this.pc;
    if (!pc) return;

    // Calculate FPS and bandwidth from frame counters
    const fps = this.frameCount - this.lastFrameCount;
    const bandwidthBytes = this.bytesReceived - this.lastBytesReceived;
    this.lastFrameCount = this.frameCount;
    this.lastBytesReceived = this.bytesReceived;

    let rttMs = -1;
    let candidateType: 'host' | 'srflx' | 'relay' | 'unknown' = 'unknown';

    try {
      const reports = await pc.getStats();
      // RTCStatsReport is a Map — use .forEach to iterate
      reports.forEach((report: RTCStats) => {
        if (report.type === 'candidate-pair') {
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          const pair = report as any;
          if (pair.nominated === true) {
            if (typeof pair.currentRoundTripTime === 'number') {
              rttMs = Math.round((pair.currentRoundTripTime as number) * 1000);
            }
            // Look up the local candidate to determine type
            const localId: string | undefined = pair.localCandidateId;
            if (localId) {
              const local = reports.get(localId) as any; // eslint-disable-line
              if (local) {
                const ct: string = local.candidateType ?? '';
                if (ct === 'host') candidateType = 'host';
                else if (ct === 'srflx') candidateType = 'srflx';
                else if (ct === 'relay') candidateType = 'relay';
              }
            }
          }
        }
      });
    } catch {
      // getStats can fail if the connection is closing — ignore
    }

    const connTypeMap: Record<'host' | 'srflx' | 'relay' | 'unknown', string> = {
      host:    'Прямое P2P (локальная сеть)',
      srflx:   'P2P через интернет (STUN)',
      relay:   'Через ретрансляционный сервер (RELAY)',
      unknown: pc.connectionState === 'connected' ? 'P2P соединение' : 'Нет подключения',
    };

    this.latestStats = {
      pcState: pc.connectionState,
      iceState: pc.iceConnectionState,
      dcState: this.framesDC?.readyState ?? 'closed',
      candidateType,
      rttMs,
      fps,
      bytesReceived: this.bytesReceived,
      bandwidthKBps: Math.round(bandwidthBytes / 1024),
      remotePeerId: this.remotePeerId ?? '',
      signalUrl: this.signalUrl,
      connectionType: connTypeMap[candidateType],
    };

    this.onStats?.(this.latestStats);
  }

  private cleanup(): void {
    this.stopStatsPolling();
    this.inputDC?.close();
    this.inputDC = null;
    this.framesDC = null;
    this.pc?.close();
    this.pc = null;
    this.frameCount = 0;
    this.lastFrameCount = 0;
    this.bytesReceived = 0;
    this.lastBytesReceived = 0;
    this.latestStats = emptyStats(this.remotePeerId ?? '', this.signalUrl);
  }
}
