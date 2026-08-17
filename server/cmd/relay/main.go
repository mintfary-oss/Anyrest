// Anyrest Relay Server
// Provides TCP-level relay when WebRTC P2P hole-punching fails.
// Two peers authenticate with an HMAC token (issued by the signaling server)
// and their streams are transparently bridged.
package main

import (
	"flag"
	"log"
	"os"

	"github.com/mintfary-oss/anyrest/server/internal/relay"
)

var addr = flag.String("addr", ":8081", "TCP listen address")

func main() {
	flag.Parse()

	secret := os.Getenv("RELAY_SECRET")
	if secret == "" {
		secret = "change-me-in-production"
	}

	srv := relay.NewServer(*addr, []byte(secret))
	log.Fatal(srv.ListenAndServe())
}
