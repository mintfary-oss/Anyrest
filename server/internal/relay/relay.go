// Package relay implements the TCP relay server used when WebRTC P2P
// hole-punching fails. Two clients authenticated with the same session
// token are joined and their traffic is forwarded transparently.
package relay

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"time"
)

const (
	// handshakeTimeout is the maximum time a client has to send its token.
	handshakeTimeout = 10 * time.Second
	// bufferSize is the copy buffer size per direction.
	bufferSize = 32 * 1024
)

// Server is the relay TCP server.
type Server struct {
	Addr      string
	SecretKey []byte

	mu       sync.Mutex
	sessions map[string]*session
}

type session struct {
	id    string
	peers [2]net.Conn
	count int
}

// NewServer creates a relay server bound to addr.
// secretKey is used to validate HMAC tokens.
func NewServer(addr string, secretKey []byte) *Server {
	return &Server{
		Addr:      addr,
		SecretKey: secretKey,
		sessions:  make(map[string]*session),
	}
}

// GenerateToken creates a time-bound HMAC-SHA256 token for a session.
func (s *Server) GenerateToken(sessionID string) string {
	h := hmac.New(sha256.New, s.SecretKey)
	// Include a 30-second timestamp bucket so tokens expire quickly.
	bucket := time.Now().Unix() / 30
	h.Write([]byte(fmt.Sprintf("%s:%d", sessionID, bucket)))
	return hex.EncodeToString(h.Sum(nil))
}

// VerifyToken checks the HMAC token, allowing one timestamp bucket of drift.
func (s *Server) VerifyToken(sessionID, token string) bool {
	bucket := time.Now().Unix() / 30
	for _, b := range []int64{bucket, bucket - 1} {
		h := hmac.New(sha256.New, s.SecretKey)
		h.Write([]byte(fmt.Sprintf("%s:%d", sessionID, b)))
		expected := hex.EncodeToString(h.Sum(nil))
		if hmac.Equal([]byte(token), []byte(expected)) {
			return true
		}
	}
	return false
}

// ListenAndServe starts the TCP relay listener.
func (s *Server) ListenAndServe() error {
	ln, err := net.Listen("tcp", s.Addr)
	if err != nil {
		return fmt.Errorf("relay listen %s: %w", s.Addr, err)
	}
	log.Printf("[relay] listening on %s", s.Addr)
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("[relay] accept error: %v", err)
			continue
		}
		go s.handleConn(conn)
	}
}

// handleConn reads the handshake line "<sessionID>:<token>\n" then
// pairs the connection with the first peer in the same session.
func (s *Server) handleConn(conn net.Conn) {
	conn.SetDeadline(time.Now().Add(handshakeTimeout))

	buf := make([]byte, 256)
	n, err := conn.Read(buf)
	if err != nil {
		conn.Close()
		return
	}
	line := string(buf[:n])
	var sessionID, token string
	if _, err := fmt.Sscanf(line, "%s %s", &sessionID, &token); err != nil || !s.VerifyToken(sessionID, token) {
		conn.Close()
		log.Printf("[relay] invalid handshake from %s", conn.RemoteAddr())
		return
	}

	conn.SetDeadline(time.Time{}) // clear deadline after auth

	s.mu.Lock()
	sess, ok := s.sessions[sessionID]
	if !ok {
		sess = &session{id: sessionID}
		s.sessions[sessionID] = sess
	}
	idx := sess.count
	sess.count++
	sess.peers[idx] = conn
	var peer1, peer2 net.Conn
	ready := sess.count >= 2
	if ready {
		peer1 = sess.peers[0]
		peer2 = sess.peers[1]
		delete(s.sessions, sessionID)
	}
	s.mu.Unlock()

	if ready {
		log.Printf("[relay] bridging session %s", sessionID)
		go pipe(peer1, peer2)
		go pipe(peer2, peer1)
	}
}

// pipe copies data from src to dst until EOF or error.
func pipe(dst, src net.Conn) {
	defer dst.Close()
	defer src.Close()
	buf := make([]byte, bufferSize)
	io.CopyBuffer(dst, src, buf) //nolint:errcheck
}
