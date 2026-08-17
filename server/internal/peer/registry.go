// Package peer manages the in-memory registry of connected agents and viewers.
package peer

import (
	"fmt"
	"math/rand/v2"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// Peer represents a connected WebSocket client (agent or viewer).
type Peer struct {
	ID        string
	Alias     string
	Conn      *websocket.Conn
	Send      chan []byte
	CreatedAt time.Time
	mu        sync.Mutex
}

// SafeWrite sends a message to the peer without racing on the connection.
func (p *Peer) SafeWrite(msgType int, data []byte) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.Conn.WriteMessage(msgType, data)
}

// Registry stores all active peers, indexed by their ID.
type Registry struct {
	mu    sync.RWMutex
	peers map[string]*Peer
}

// NewRegistry creates an empty registry.
func NewRegistry() *Registry {
	return &Registry{peers: make(map[string]*Peer)}
}

// Register adds a new peer and assigns it a unique numeric ID.
func (r *Registry) Register(conn *websocket.Conn, alias string) *Peer {
	id := r.generateID()
	p := &Peer{
		ID:        id,
		Alias:     alias,
		Conn:      conn,
		Send:      make(chan []byte, 256),
		CreatedAt: time.Now(),
	}
	r.mu.Lock()
	r.peers[id] = p
	r.mu.Unlock()
	return p
}

// Unregister removes a peer by ID.
func (r *Registry) Unregister(id string) {
	r.mu.Lock()
	delete(r.peers, id)
	r.mu.Unlock()
}

// Get looks up a peer by ID.
func (r *Registry) Get(id string) (*Peer, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.peers[id]
	return p, ok
}

// Count returns the number of active peers.
func (r *Registry) Count() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.peers)
}

// generateID produces a 9-digit numeric string (like AnyDesk IDs).
func (r *Registry) generateID() string {
	for {
		id := fmt.Sprintf("%09d", rand.IntN(999_999_999)+1)
		r.mu.RLock()
		_, exists := r.peers[id]
		r.mu.RUnlock()
		if !exists {
			return id
		}
	}
}
