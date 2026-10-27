// Wasl relay: forwards encrypted frames between devices in the same room.
// It never sees plaintext; frames are AES-GCM sealed with the pairing key.
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const maxPerRoom = 8

// ponytail: one global lock; per-room locks if a single box ever carries thousands of pairs.
var (
	mu    sync.Mutex
	rooms = map[string]map[*websocket.Conn]bool{}
)

func main() {
	tokens := map[string]bool{}
	for _, t := range strings.Split(os.Getenv("WASL_TOKENS"), ",") {
		if t = strings.TrimSpace(t); t != "" {
			tokens[t] = true
		}
	}
	if len(tokens) == 0 {
		log.Fatal("set WASL_TOKENS=token1,token2 (one invite token per person)")
	}
	addr := os.Getenv("WASL_ADDR")
	if addr == "" {
		addr = ":8080"
	}

	http.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		room := q.Get("room")
		if !tokens[q.Get("token")] || len(room) != 32 {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		c.SetReadLimit(1 << 20)
		if !join(room, c) {
			c.Close(websocket.StatusPolicyViolation, "room full")
			return
		}
		defer leave(room, c)

		ctx, cancel := context.WithCancel(r.Context())
		defer cancel()
		go keepalive(ctx, c)
		for {
			typ, data, err := c.Read(ctx)
			if err != nil {
				return
			}
			for _, p := range peers(room, c) {
				wctx, done := context.WithTimeout(ctx, 5*time.Second)
				p.Write(wctx, typ, data) // a dead peer cleans itself up in its own read loop
				done()
			}
		}
	})
	log.Printf("wasl relay on %s, %d tokens", addr, len(tokens))
	log.Fatal(http.ListenAndServe(addr, nil))
}

func join(room string, c *websocket.Conn) bool {
	mu.Lock()
	defer mu.Unlock()
	if rooms[room] == nil {
		rooms[room] = map[*websocket.Conn]bool{}
	}
	if len(rooms[room]) >= maxPerRoom {
		return false
	}
	rooms[room][c] = true
	return true
}

func leave(room string, c *websocket.Conn) {
	mu.Lock()
	defer mu.Unlock()
	delete(rooms[room], c)
	if len(rooms[room]) == 0 {
		delete(rooms, room)
	}
}

func peers(room string, self *websocket.Conn) []*websocket.Conn {
	mu.Lock()
	defer mu.Unlock()
	var out []*websocket.Conn
	for p := range rooms[room] {
		if p != self {
			out = append(out, p)
		}
	}
	return out
}

// Pings keep NAT/proxy mappings alive and detect silently dead clients.
func keepalive(ctx context.Context, c *websocket.Conn) {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			pctx, done := context.WithTimeout(ctx, 10*time.Second)
			err := c.Ping(pctx)
			done()
			if err != nil {
				c.CloseNow()
				return
			}
		}
	}
}
