// Anyrest Desktop Agent
// Connects to the signaling server, registers a peer ID, and accepts
// WebRTC connections from web viewers. Streams the local display as
// JPEG frames and injects received mouse/keyboard events.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/mintfary-oss/anyrest/agent/internal/agent"
	"github.com/mintfary-oss/anyrest/agent/internal/capture"
	"github.com/mintfary-oss/anyrest/agent/internal/input"
)

var (
	signalURL  = flag.String("signal", "ws://localhost:8080/ws", "Signaling server WebSocket URL")
	displayIdx = flag.Int("display", 0, "Display index to capture (0 = primary)")
	fps        = flag.Int("fps", 15, "Target frame rate (1-30)")
	quality    = flag.Int("quality", 75, "JPEG quality (1-100)")
	displayStr = flag.String("x-display", ":0", "X11 DISPLAY value (Linux only)")
)

func main() {
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, `Anyrest Agent %s — self-hosted remote desktop

Usage:
  anyrest-agent [flags]

Flags:
`, version())
		flag.PrintDefaults()
	}
	flag.Parse()

	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("[anyrest] ")

	n := capture.DisplayCount()
	log.Printf("detected %d display(s)", n)
	if n == 0 {
		log.Fatal("no active displays found — make sure a display server is running")
	}

	inj := input.NewDefaultInjector(*displayStr)

	cfg := agent.Config{
		SignalURL:   *signalURL,
		DisplayIdx:  *displayIdx,
		FPS:         *fps,
		JPEGQuality: *quality,
	}

	a := agent.New(cfg, inj)

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	log.Printf("agent starting — signal=%s display=%d fps=%d", cfg.SignalURL, cfg.DisplayIdx, cfg.FPS)
	if err := a.Run(ctx); err != nil && err != context.Canceled {
		log.Fatal(err)
	}
	log.Println("agent stopped")
}

func version() string {
	return "v0.1.0"
}
