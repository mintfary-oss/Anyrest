// Package protocol defines the WebSocket message types exchanged between
// the signaling server and all clients (agents and web viewers).
package protocol

// MessageType identifies the kind of signaling message.
type MessageType string

const (
	// MsgRegister is sent by an agent to register itself with a unique ID.
	MsgRegister MessageType = "register"

	// MsgRegisterAck acknowledges a successful registration and returns the assigned peer ID.
	MsgRegisterAck MessageType = "register_ack"

	// MsgConnect is sent by a viewer to request a connection to a remote agent.
	MsgConnect MessageType = "connect"

	// MsgConnectAck is forwarded to the agent when a viewer wants to connect.
	MsgConnectAck MessageType = "connect_ack"

	// MsgOffer carries a WebRTC SDP offer from the initiating peer.
	MsgOffer MessageType = "offer"

	// MsgAnswer carries a WebRTC SDP answer from the responding peer.
	MsgAnswer MessageType = "answer"

	// MsgICECandidate carries a WebRTC ICE candidate for NAT traversal.
	MsgICECandidate MessageType = "ice_candidate"

	// MsgRelay signals that P2P failed and the relay server should be used.
	MsgRelay MessageType = "relay"

	// MsgDisconnect notifies the peer that the session has ended.
	MsgDisconnect MessageType = "disconnect"

	// MsgError carries an error description back to the client.
	MsgError MessageType = "error"

	// MsgPing / MsgPong are heartbeat messages.
	MsgPing MessageType = "ping"
	MsgPong MessageType = "pong"
)

// Message is the envelope for every WebSocket frame.
type Message struct {
	Type    MessageType `json:"type"`
	From    string      `json:"from,omitempty"`
	To      string      `json:"to,omitempty"`
	Payload interface{} `json:"payload,omitempty"`
}

// RegisterPayload is the body of a MsgRegister message.
type RegisterPayload struct {
	// Alias is an optional human-readable name for the agent.
	Alias string `json:"alias,omitempty"`
}

// RegisterAckPayload confirms registration with the assigned peer ID.
type RegisterAckPayload struct {
	PeerID    string `json:"peer_id"`
	RelayAddr string `json:"relay_addr"` // host:port of the relay server
}

// ConnectPayload requests a connection to a target agent.
type ConnectPayload struct {
	TargetID string `json:"target_id"`
}

// SDPPayload wraps a WebRTC session description.
type SDPPayload struct {
	Type string `json:"type"` // "offer" | "answer"
	SDP  string `json:"sdp"`
}

// ICECandidatePayload wraps a Trickle-ICE candidate.
type ICECandidatePayload struct {
	Candidate        string `json:"candidate"`
	SDPMid           string `json:"sdpMid"`
	SDPMLineIndex    uint16 `json:"sdpMLineIndex"`
	UsernameFragment string `json:"usernameFragment,omitempty"`
}

// RelayPayload tells clients to use the relay instead of P2P.
type RelayPayload struct {
	RelayAddr string `json:"relay_addr"`
	SessionID string `json:"session_id"`
	Token     string `json:"token"` // HMAC-signed token for relay auth
}

// ErrorPayload describes a signaling error.
type ErrorPayload struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}
