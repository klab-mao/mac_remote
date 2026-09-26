package main

import (
	"encoding/binary"
	"log"
	"net"
	"sync"
	"time"
)

var bindMagic = []byte("RMBD")

const (
	bindSideHost   = 1
	bindSideClient = 2
)

type relaySession struct {
	id       uint64
	host     *net.UDPAddr
	client   *net.UDPAddr
	lastSeen time.Time
}

type udpRelay struct {
	port     int
	conn     *net.UDPConn
	mu       sync.Mutex
	sessions map[uint64]*relaySession
	byAddr   map[string]*relaySession
}

func newUDPRelay(port int) (*udpRelay, error) {
	conn, err := net.ListenUDP("udp", &net.UDPAddr{Port: port})
	if err != nil {
		return nil, err
	}
	return &udpRelay{
		port:     port,
		conn:     conn,
		sessions: map[uint64]*relaySession{},
		byAddr:   map[string]*relaySession{},
	}, nil
}

func (r *udpRelay) run() {
	buf := make([]byte, 65536)
	for {
		n, addr, err := r.conn.ReadFromUDP(buf)
		if err != nil {
			log.Printf("udp read: %v", err)
			continue
		}
		r.handlePacket(buf[:n], addr)
	}
}

func (r *udpRelay) handlePacket(b []byte, addr *net.UDPAddr) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if len(b) >= 13 && string(b[:4]) == string(bindMagic) {
		id := binary.LittleEndian.Uint64(b[4:12])
		s := r.sessions[id]
		if s == nil {
			return
		}
		switch b[12] {
		case bindSideHost:
			s.host = addr
		case bindSideClient:
			s.client = addr
		default:
			return
		}
		s.lastSeen = time.Now()
		r.byAddr[addr.String()] = s
		log.Printf("session %d: bound %s endpoint %s", id, sideName(b[12]), addr)
		return
	}

	s := r.byAddr[addr.String()]
	if s == nil {
		return
	}
	s.lastSeen = time.Now()

	var dst *net.UDPAddr
	if s.host != nil && addr.String() == s.host.String() {
		dst = s.client
	} else {
		dst = s.host
	}
	if dst == nil {
		return
	}
	_, _ = r.conn.WriteToUDP(b, dst)
}

func (r *udpRelay) createSession(id uint64) {
	r.mu.Lock()
	r.sessions[id] = &relaySession{id: id, lastSeen: time.Now()}
	r.mu.Unlock()
}

func (r *udpRelay) cleanupLoop() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		r.mu.Lock()
		now := time.Now()
		for id, s := range r.sessions {
			if now.Sub(s.lastSeen) > idleTimeout {
				if s.host != nil {
					delete(r.byAddr, s.host.String())
				}
				if s.client != nil {
					delete(r.byAddr, s.client.String())
				}
				delete(r.sessions, id)
				log.Printf("session %d expired (idle)", id)
			}
		}
		r.mu.Unlock()
	}
}

func sideName(side byte) string {
	if side == bindSideHost {
		return "host"
	}
	return "client"
}
