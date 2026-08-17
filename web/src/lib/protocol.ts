// Protocol types — must stay in sync with server/internal/protocol/messages.go

export type MessageType =
  | 'register'
  | 'register_ack'
  | 'connect'
  | 'connect_ack'
  | 'offer'
  | 'answer'
  | 'ice_candidate'
  | 'relay'
  | 'disconnect'
  | 'error'
  | 'ping'
  | 'pong';

export interface SignalMessage {
  type: MessageType;
  from?: string;
  to?: string;
  payload?: unknown;
}

export interface RegisterAckPayload {
  peer_id: string;
  relay_addr: string;
}

export interface ConnectPayload {
  target_id: string;
}

export interface SDPPayload {
  type: 'offer' | 'answer';
  sdp: string;
}

export interface ICECandidatePayload {
  candidate: string;
  sdpMid: string;
  sdpMLineIndex: number;
  usernameFragment?: string;
}

export interface RelayPayload {
  relay_addr: string;
  session_id: string;
  token: string;
}

export interface ErrorPayload {
  code: number;
  message: string;
}

// ── Input events sent over the WebRTC data channel ───────────────────────────

export type InputEventType =
  | 'mousemove'
  | 'mousedown'
  | 'mouseup'
  | 'scroll'
  | 'keydown'
  | 'keyup';

export interface MouseMoveEvent {
  type: 'mousemove';
  /** Normalised 0–1 coordinates relative to the remote screen. */
  nx: number;
  ny: number;
}

export interface MouseButtonEvent {
  type: 'mousedown' | 'mouseup';
  button: number; // 0=left 1=middle 2=right
  nx: number;
  ny: number;
}

export interface ScrollEvent {
  type: 'scroll';
  dx: number;
  dy: number;
}

export interface KeyEvent {
  type: 'keydown' | 'keyup';
  key: string;
  code: string;
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
  meta: boolean;
}

export type InputEvent =
  | MouseMoveEvent
  | MouseButtonEvent
  | ScrollEvent
  | KeyEvent;
