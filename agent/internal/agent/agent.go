// Package agent implements the Anyrest desktop agent.
// It registers with the signaling server, waits for viewer connections,
// establishes WebRTC peer connections, and streams JPEG screen frames
// over a data channel while injecting received input events locally.
package agent

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	"github.com/pion/webrtc/v4"

	"github.com/mintfary-oss/anyrest/agent/internal/capture"
	"github.com/mintfary-oss/anyrest/agent/internal/input"
)

// MessageType mirrors server/internal/protocol/messages.go
type MessageType string

const (
	msgRegister      MessageType = "register"
	msgRegisterAck   MessageType = "register_ack"
	msgConnect       MessageType = "connect"
	msgConnectAck    MessageType = "connect_ack"
	msgOffer         MessageType = "offer"
	msgAnswer        MessageType = "answer"
	msgICECandidate  MessageType = "ice_candidate"
	msgRelay         MessageType = "relay"
	msgDisconnect    MessageType = "disconnect"
	msgError         MessageType = "error"
	msgPing          MessageType = "ping"
	msgPong          MessageType = "pong"
)

type signalMsg struct {
	Type    MessageType     `json:"type"`
	From    string          `json:"from,omitempty"`
	To      string          `json:"to,omitempty"`
	Payload json.RawMessage `json:"payload,omitempty"`
}

// frameHeader is prepended to every JPEG frame sent over the data channel.
// Format: [magic:4][width:2][height:2][seq:4] = 12 bytes
const frameMagic uint32 = 0xA2E501F2

// frameMsg is the binary frame header.
type frameMsg struct {
	Magic  uint32
	Width  uint16
	Height uint16
	Seq    uint32
}

// inputEvent mirrors web/src/lib/protocol.ts InputEvent.
type inputEvent struct {
	Type   string  `json:"type"`
	NX     float64 `json:"nx"`
	NY     float64 `json:"ny"`
	Button int     `json:"button"`
	DX     float64 `json:"dx"`
	DY     float64 `json:"dy"`
	Key    string  `json:"key"`
	Code   string  `json:"code"`
	Ctrl   bool    `json:"ctrl"`
	Alt    bool    `json:"alt"`
	Shift  bool    `json:"shift"`
	Meta   bool    `json:"meta"`
}

// Config holds agent configuration.
type Config struct {
	SignalURL   string
	DisplayIdx  int
	FPS         int
	JPEGQuality int
	DisplayW    int // pixel width for coordinate scaling
	DisplayH    int // pixel height for coordinate scaling
}

// Agent manages signaling, WebRTC, capture, and input.
type Agent struct {
	cfg      Config
	capturer *capture.Capturer
	injector input.Injector

	mu       sync.Mutex
	sessions map[string]*session // keyed by viewer peer ID
}

type session struct {
	pc         *webrtc.PeerConnection
	frameCh    *webrtc.DataChannel
	viewerID   string
	cancelLoop context.CancelFunc
}

// New creates an Agent with the given configuration.
func New(cfg Config, inj input.Injector) *Agent {
	if cfg.FPS <= 0 {
		cfg.FPS = 15
	}
	return &Agent{
		cfg:      cfg,
		capturer: capture.New(cfg.DisplayIdx, cfg.JPEGQuality),
		injector: inj,
		sessions: make(map[string]*session),
	}
}

// Run connects to the signaling server and blocks until ctx is done.
func (a *Agent) Run(ctx context.Context) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := a.runOnce(ctx); err != nil {
			log.Printf("[agent] disconnected: %v — retrying in 3s", err)
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(3 * time.Second):
			}
		}
	}
}

func (a *Agent) runOnce(ctx context.Context) error {
	dialer := websocket.DefaultDialer
	conn, _, err := dialer.DialContext(ctx, a.cfg.SignalURL, nil)
	if err != nil {
		return fmt.Errorf("dial signal: %w", err)
	}
	defer conn.Close()

	log.Printf("[agent] connected to signal server %s", a.cfg.SignalURL)

	// Register
	a.send(conn, signalMsg{
		Type:    msgRegister,
		Payload: json.RawMessage(`{}`),
	})

	// Read loop
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		var msg signalMsg
		if err := conn.ReadJSON(&msg); err != nil {
			return fmt.Errorf("read: %w", err)
		}
		a.handle(ctx, conn, msg)
	}
}

func (a *Agent) handle(ctx context.Context, conn *websocket.Conn, msg signalMsg) {
	switch msg.Type {
	case msgRegisterAck:
		var pl struct {
			PeerID    string `json:"peer_id"`
			RelayAddr string `json:"relay_addr"`
		}
		json.Unmarshal(msg.Payload, &pl) //nolint:errcheck
		log.Printf("[agent] registered — ID: %s", pl.PeerID)

	case msgConnectAck:
		// A viewer wants to connect — we become the offer sender
		var pl struct {
			TargetID string `json:"target_id"`
		}
		json.Unmarshal(msg.Payload, &pl) //nolint:errcheck
		viewerID := msg.From
		if viewerID == "" {
			viewerID = pl.TargetID
		}
		log.Printf("[agent] viewer %s connecting", viewerID)
		go a.startSession(ctx, conn, viewerID)

	case msgAnswer:
		var pl struct {
			SDP string `json:"sdp"`
		}
		json.Unmarshal(msg.Payload, &pl) //nolint:errcheck
		a.mu.Lock()
		sess := a.sessions[msg.From]
		a.mu.Unlock()
		if sess != nil {
			err := sess.pc.SetRemoteDescription(webrtc.SessionDescription{
				Type: webrtc.SDPTypeAnswer,
				SDP:  pl.SDP,
			})
			if err != nil {
				log.Printf("[agent] set remote desc: %v", err)
			}
		}

	case msgICECandidate:
		var pl struct {
			Candidate        string `json:"candidate"`
			SDPMid           string `json:"sdpMid"`
			SDPMLineIndex    uint16 `json:"sdpMLineIndex"`
		}
		json.Unmarshal(msg.Payload, &pl) //nolint:errcheck
		a.mu.Lock()
		sess := a.sessions[msg.From]
		a.mu.Unlock()
		if sess != nil && pl.Candidate != "" {
			mLineIdx := pl.SDPMLineIndex
			sess.pc.AddICECandidate(webrtc.ICECandidateInit{ //nolint:errcheck
				Candidate:        pl.Candidate,
				SDPMid:           &pl.SDPMid,
				SDPMLineIndex:    &mLineIdx,
			})
		}

	case msgDisconnect:
		a.closeSession(msg.From)

	case msgPing:
		a.send(conn, signalMsg{Type: msgPong})

	case msgError:
		var pl struct{ Message string `json:"message"` }
		json.Unmarshal(msg.Payload, &pl) //nolint:errcheck
		log.Printf("[agent] signaling error: %s", pl.Message)
	}
}

// startSession creates a WebRTC peer connection for a viewer and sends an offer.
func (a *Agent) startSession(ctx context.Context, conn *websocket.Conn, viewerID string) {
	// Multiple STUN servers for reliability — Google may be blocked in Russia.
	// stunprotocol.org and ekiga.net are widely accessible alternatives.
	iceServers := []webrtc.ICEServer{
		{URLs: []string{
			"stun:stun.l.google.com:19302",
			"stun:stun1.l.google.com:19302",
			"stun:stun.stunprotocol.org:3478",
			"stun:stun.ekiga.net:3478",
			"stun:stun.ideasip.com:3478",
		}},
	}
	pc, err := webrtc.NewPeerConnection(webrtc.Configuration{
		ICEServers: iceServers,
	})
	if err != nil {
		log.Printf("[agent] new PC: %v", err)
		return
	}

	// Data channel for JPEG frames (binary, ordered)
	frameDC, err := pc.CreateDataChannel("frames", &webrtc.DataChannelInit{
		Ordered: boolPtr(true),
	})
	if err != nil {
		log.Printf("[agent] create frame dc: %v", err)
		pc.Close()
		return
	}

	loopCtx, cancelLoop := context.WithCancel(ctx)

	sess := &session{
		pc:         pc,
		frameCh:    frameDC,
		viewerID:   viewerID,
		cancelLoop: cancelLoop,
	}

	a.mu.Lock()
	a.sessions[viewerID] = sess
	a.mu.Unlock()

	// Handle incoming data channel (for input events)
	pc.OnDataChannel(func(dc *webrtc.DataChannel) {
		if dc.Label() == "input" {
			dc.OnMessage(func(msg webrtc.DataChannelMessage) {
				a.handleInput(msg.Data)
			})
		}
	})

	// ICE candidate trickle
	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil {
			return
		}
		ci := c.ToJSON()
		payload, _ := json.Marshal(map[string]interface{}{
			"candidate":        ci.Candidate,
			"sdpMid":           strOrEmpty(ci.SDPMid),
			"sdpMLineIndex":    uintOrZero(ci.SDPMLineIndex),
			"usernameFragment": strOrEmpty(ci.UsernameFragment),
		})
		a.send(conn, signalMsg{
			Type:    msgICECandidate,
			To:      viewerID,
			Payload: payload,
		})
	})

	pc.OnConnectionStateChange(func(s webrtc.PeerConnectionState) {
		log.Printf("[agent] connection state → %s (viewer=%s)", s, viewerID)
		if s == webrtc.PeerConnectionStateDisconnected ||
			s == webrtc.PeerConnectionStateFailed ||
			s == webrtc.PeerConnectionStateClosed {
			a.closeSession(viewerID)
		}
	})

	// Start frame streaming when the data channel opens
	frameDC.OnOpen(func() {
		log.Printf("[agent] frame channel open for viewer %s", viewerID)
		go a.streamFrames(loopCtx, frameDC)
	})

	// Create and send offer
	offer, err := pc.CreateOffer(nil)
	if err != nil {
		log.Printf("[agent] create offer: %v", err)
		a.closeSession(viewerID)
		return
	}
	if err := pc.SetLocalDescription(offer); err != nil {
		log.Printf("[agent] set local desc: %v", err)
		a.closeSession(viewerID)
		return
	}

	payload, _ := json.Marshal(map[string]string{
		"type": "offer",
		"sdp":  offer.SDP,
	})
	a.send(conn, signalMsg{
		Type:    msgOffer,
		To:      viewerID,
		Payload: payload,
	})
	log.Printf("[agent] sent offer to viewer %s", viewerID)
}

// streamFrames captures the screen and sends JPEG frames at the configured FPS.
func (a *Agent) streamFrames(ctx context.Context, dc *webrtc.DataChannel) {
	ticker := time.NewTicker(time.Second / time.Duration(a.cfg.FPS))
	defer ticker.Stop()

	var seq uint32
	headerBuf := make([]byte, 12)

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}

		if dc.ReadyState() != webrtc.DataChannelStateOpen {
			return
		}

		frame, err := a.capturer.Capture()
		if err != nil {
			log.Printf("[agent] capture: %v", err)
			continue
		}

		// Build header
		binary.LittleEndian.PutUint32(headerBuf[0:4], frameMagic)
		binary.LittleEndian.PutUint16(headerBuf[4:6], uint16(frame.Width))
		binary.LittleEndian.PutUint16(headerBuf[6:8], uint16(frame.Height))
		binary.LittleEndian.PutUint32(headerBuf[8:12], seq)
		seq++

		// Combine header + JPEG data
		msg := make([]byte, 12+len(frame.JPEG))
		copy(msg[:12], headerBuf)
		copy(msg[12:], frame.JPEG)

		if err := dc.Send(msg); err != nil {
			log.Printf("[agent] send frame: %v", err)
			return
		}
	}
}

// handleInput decodes an input event JSON message and injects it.
func (a *Agent) handleInput(data []byte) {
	var ev inputEvent
	if err := json.Unmarshal(data, &ev); err != nil {
		return
	}

	// Always use actual display bounds so coordinates are correct regardless
	// of the resolution the viewer is displaying at.
	// capture.DisplaySize falls back to 1920×1080 if no display is found.
	w, h := capture.DisplaySize(a.cfg.DisplayIdx)
	absX := int(ev.NX * float64(w))
	absY := int(ev.NY * float64(h))

	var err error
	switch ev.Type {
	case "mousemove":
		err = a.injector.MouseMove(absX, absY)
	case "mousedown":
		_ = a.injector.MouseMove(absX, absY)
		err = a.injector.MouseDown(ev.Button)
	case "mouseup":
		err = a.injector.MouseUp(ev.Button)
	case "scroll":
		err = a.injector.Scroll(int(ev.DX), int(ev.DY))
	case "keydown":
		err = a.injector.KeyDown(ev.Key, ev.Code)
	case "keyup":
		err = a.injector.KeyUp(ev.Key, ev.Code)
	}
	if err != nil {
		log.Printf("[agent] input %s: %v", ev.Type, err)
	}
}

// closeSession tears down a viewer session.
func (a *Agent) closeSession(viewerID string) {
	a.mu.Lock()
	sess, ok := a.sessions[viewerID]
	if ok {
		delete(a.sessions, viewerID)
	}
	a.mu.Unlock()
	if ok {
		sess.cancelLoop()
		sess.pc.Close()
		log.Printf("[agent] session closed for viewer %s", viewerID)
	}
}

// send marshals and writes a message to the WebSocket connection.
func (a *Agent) send(conn *websocket.Conn, msg signalMsg) {
	if err := conn.WriteJSON(msg); err != nil {
		log.Printf("[agent] send %s: %v", msg.Type, err)
	}
}

// ── Helpers ───────────────────────────────────────────────────────────────

func boolPtr(b bool) *bool { return &b }

func strOrEmpty(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func uintOrZero(p *uint16) uint16 {
	if p == nil {
		return 0
	}
	return *p
}

// sessionID generates a random hex session ID for relay fallback.
func sessionID() string {
	return uuid.New().String()
}

// suppress unused variable warning
var _ = sessionID
