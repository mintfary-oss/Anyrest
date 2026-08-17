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

const FRAME_MAGIC = 0xa2e501f2;
const HEADER_SIZE = 12; // magic(4) + width(2) + height(2) + seq(4)

const ICE_SERVERS: RTCIceServer[] = [
  { urls: 'stun:stun.l.google.com:19302' },
  { urls: 'stun:stun1.l.google.com:19302' },
];

export class WebRTCViewer {
  private pc: RTCPeerConnection | null = null;
  private inputDC: RTCDataChannel | null = null;
  private remotePeerId: string | null = null;

  constructor(
    private readonly signaling: SignalingClient,
    private readonly onStateChange: StateChangeHandler,
    private readonly onFrame: FrameHandler,
  ) {
    this.bindSignalingHandlers();
  }

  // ── Public API ────────────────────────────────────────────────────────────

  async startSession(remotePeerId: string): Promise<void> {
    this.remotePeerId = remotePeerId;
    this.onStateChange('connecting');
    this.signaling.connectTo(remotePeerId);
    // Waits for 'offer' from the agent
  }

  sendInput(event: InputEvent): void {
    if (this.inputDC?.readyState === 'open') {
      this.inputDC.send(JSON.stringify(event));
    }
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

    // Payload starts after the 12-byte header
    const jpeg = buf.slice(HEADER_SIZE);
    const blob = new Blob([jpeg], { type: 'image/jpeg' });
    const url = URL.createObjectURL(blob);
    this.onFrame(url);
  }

  private cleanup(): void {
    this.inputDC?.close();
    this.inputDC = null;
    this.pc?.close();
    this.pc = null;
  }
}
