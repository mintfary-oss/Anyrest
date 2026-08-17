// Anyrest Signaling Server
// Handles WebSocket connections from agents (hosts) and viewers (clients).
// Brokers WebRTC offer/answer/ICE exchanges and falls back to the relay.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/gorilla/websocket"
	"github.com/google/uuid"

	"github.com/mintfary-oss/anyrest/server/internal/peer"
	"github.com/mintfary-oss/anyrest/server/internal/protocol"
	"github.com/mintfary-oss/anyrest/server/internal/relay"
)

var (
	addr      = flag.String("addr", ":8080", "HTTP listen address")
	tlsCert   = flag.String("cert", "", "TLS certificate file (PEM)")
	tlsKey    = flag.String("key", "", "TLS key file (PEM)")
	relayAddr = flag.String("relay", "localhost:8081", "Public address of the relay server")
)

var upgrader = websocket.Upgrader{
	HandshakeTimeout: 10 * time.Second,
	ReadBufferSize:   4096,
	WriteBufferSize:  4096,
	// Allow all origins so the web client can connect from any IP.
	CheckOrigin: func(r *http.Request) bool { return true },
}

// relaySecret is shared between signal and relay processes via env var.
var relaySecret []byte

var registry *peer.Registry

func main() {
	flag.Parse()

	secret := os.Getenv("RELAY_SECRET")
	if secret == "" {
		secret = "change-me-in-production"
	}
	relaySecret = []byte(secret)

	registry = peer.NewRegistry()

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", handleWS)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"status":"ok","peers":%d}`, registry.Count())
	})

	log.Printf("[signal] starting on %s", *addr)
	var err error
	if *tlsCert != "" && *tlsKey != "" {
		err = http.ListenAndServeTLS(*addr, *tlsCert, *tlsKey, mux)
	} else {
		err = http.ListenAndServe(*addr, mux)
	}
	if err != nil {
		log.Fatal(err)
	}
}

// handleWS upgrades the connection and starts the read/write pumps.
func handleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[signal] upgrade error: %v", err)
		return
	}
	// Each connection gets registered once it sends MsgRegister.
	go serve(conn)
}

// serve is the main loop for a single WebSocket connection.
func serve(conn *websocket.Conn) {
	var p *peer.Peer
	defer func() {
		if p != nil {
			registry.Unregister(p.ID)
			log.Printf("[signal] peer %s disconnected", p.ID)
		}
		conn.Close()
	}()

	conn.SetReadLimit(64 * 1024)
	conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})

	// Heartbeat goroutine.
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	go func() {
		for range ticker.C {
			if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}()

	for {
		_, raw, err := conn.ReadMessage()
		if err != nil {
			return
		}
		conn.SetReadDeadline(time.Now().Add(60 * time.Second))

		var msg protocol.Message
		if err := json.Unmarshal(raw, &msg); err != nil {
			sendError(conn, 400, "invalid JSON")
			continue
		}

		switch msg.Type {
		case protocol.MsgRegister:
			p = handleRegister(conn, msg)

		case protocol.MsgConnect:
			if p == nil {
				sendError(conn, 403, "not registered")
				continue
			}
			handleConnect(p, msg)

		case protocol.MsgOffer, protocol.MsgAnswer, protocol.MsgICECandidate:
			if p == nil {
				sendError(conn, 403, "not registered")
				continue
			}
			forward(p, msg)

		case protocol.MsgDisconnect:
			return

		case protocol.MsgPing:
			send(conn, protocol.Message{Type: protocol.MsgPong})

		default:
			sendError(conn, 400, "unknown message type")
		}
	}
}

// handleRegister registers the peer and returns its assigned ID.
func handleRegister(conn *websocket.Conn, msg protocol.Message) *peer.Peer {
	var pl protocol.RegisterPayload
	if msg.Payload != nil {
		payloadBytes, _ := json.Marshal(msg.Payload)
		json.Unmarshal(payloadBytes, &pl) //nolint:errcheck
	}

	p := registry.Register(conn, pl.Alias)
	log.Printf("[signal] registered peer %s (alias=%q)", p.ID, p.Alias)

	send(conn, protocol.Message{
		Type: protocol.MsgRegisterAck,
		Payload: protocol.RegisterAckPayload{
			PeerID:    p.ID,
			RelayAddr: *relayAddr,
		},
	})
	return p
}

// handleConnect notifies the target agent that a viewer wants to connect.
func handleConnect(from *peer.Peer, msg protocol.Message) {
	var pl protocol.ConnectPayload
	payloadBytes, _ := json.Marshal(msg.Payload)
	if err := json.Unmarshal(payloadBytes, &pl); err != nil || pl.TargetID == "" {
		sendError(from.Conn, 400, "missing target_id")
		return
	}

	target, ok := registry.Get(pl.TargetID)
	if !ok {
		sendError(from.Conn, 404, "peer not found")
		return
	}

	send(target.Conn, protocol.Message{
		Type: protocol.MsgConnectAck,
		From: from.ID,
		Payload: protocol.ConnectPayload{
			TargetID: from.ID,
		},
	})
	log.Printf("[signal] connect request %s -> %s", from.ID, target.ID)
}

// forward routes offer/answer/ICE messages between peers.
func forward(from *peer.Peer, msg protocol.Message) {
	if msg.To == "" {
		sendError(from.Conn, 400, "missing 'to' field")
		return
	}
	target, ok := registry.Get(msg.To)
	if !ok {
		// Peer gone — suggest relay fallback.
		relaySess := uuid.New().String()
		rs := relay.NewServer("", relaySecret) // used only for token generation
		send(from.Conn, protocol.Message{
			Type: protocol.MsgRelay,
			Payload: protocol.RelayPayload{
				RelayAddr: *relayAddr,
				SessionID: relaySess,
				Token:     rs.GenerateToken(relaySess),
			},
		})
		return
	}
	msg.From = from.ID
	send(target.Conn, msg)
}

// send serialises and writes a message to a connection.
func send(conn *websocket.Conn, msg protocol.Message) {
	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("[signal] marshal error: %v", err)
		return
	}
	if err := conn.WriteMessage(websocket.TextMessage, data); err != nil {
		log.Printf("[signal] write error: %v", err)
	}
}

// sendError sends a protocol.MsgError back to the caller.
func sendError(conn *websocket.Conn, code int, message string) {
	send(conn, protocol.Message{
		Type:    protocol.MsgError,
		Payload: protocol.ErrorPayload{Code: code, Message: message},
	})
}
