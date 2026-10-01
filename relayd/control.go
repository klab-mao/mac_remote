package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"time"
)

const (
	frChallenge   uint16 = 1
	frAuthHost    uint16 = 2
	frAuthUser    uint16 = 3
	frOK          uint16 = 4
	frErr         uint16 = 5
	frConnectReq  uint16 = 6
	frSessionInfo uint16 = 7
	frPing        uint16 = 8
	frPong        uint16 = 9
	frData        uint16 = 10
)

const (
	authTimeout  = 15 * time.Second
	idleTimeout  = 120 * time.Second
	maxFrameSize = 4 << 20
)

type tcpSession struct {
	hostConn     net.Conn
	viewerConn   net.Conn
	hostDeviceID string
	writeCh      chan []byte
	done         chan struct{}
}

type controlHub struct {
	mu            sync.Mutex
	accounts      *Accounts
	relay         *udpRelay
	hosts         map[string]net.Conn
	tcpSessions   map[uint64]*tcpSession
	sessionByConn map[net.Conn]uint64
}

func (h *controlHub) registerHost(deviceID string, conn net.Conn) {
	h.mu.Lock()
	h.hosts[deviceID] = conn
	type resendItem struct {
		sid  uint64
		conn net.Conn
	}
	var resends []resendItem
	for sid, ts := range h.tcpSessions {
		if ts.hostDeviceID == deviceID && ts.hostConn != conn {
			if ts.hostConn != nil {
				delete(h.sessionByConn, ts.hostConn)
			}
			ts.hostConn = conn
			h.sessionByConn[conn] = sid
			resends = append(resends, resendItem{sid, conn})
		}
	}
	h.mu.Unlock()
	for _, r := range resends {
		info := make([]byte, 10)
		binary.LittleEndian.PutUint64(info, r.sid)
		binary.LittleEndian.PutUint16(info[8:], uint16(h.relay.port))
		if err := writeFrame(r.conn, frSessionInfo, info); err != nil {
			log.Printf("re-send sessionInfo error: %v", err)
		} else {
			log.Printf("re-sent sessionInfo %d to reconnected host %s", r.sid, deviceID)
		}
	}
}

func (h *controlHub) unregisterHost(deviceID string, conn net.Conn) {
	h.mu.Lock()
	if h.hosts[deviceID] == conn {
		delete(h.hosts, deviceID)
	}
	h.mu.Unlock()
}

func (h *controlHub) lookupHost(deviceID string) net.Conn {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.hosts[deviceID]
}

func handleControl(conn net.Conn, hub *controlHub) {
	defer conn.Close()

	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return
	}
	if err := writeFrame(conn, frChallenge, nonce); err != nil {
		return
	}

	var role, name string
	authed := false

	for {
		_ = conn.SetReadDeadline(time.Now().Add(idleTimeout))
		typ, payload, err := readFrame(conn)
		if err != nil {
			break
		}

		switch typ {
		case frPing:
			_ = writeFrame(conn, frPong, nil)
			log.Printf("ping from %s — pong sent", conn.RemoteAddr())

		case frAuthHost:
			name, err = verifyAuth(payload, nonce, hub.accounts.Hosts)
			if err != nil {
				_ = writeFrame(conn, frErr, strPayload(err.Error()))
				break
			}
			role = "host"
			authed = true
			hub.registerHost(name, conn)
			_ = writeFrame(conn, frOK, nil)
			log.Printf("host device registered: %s (%s)", name, conn.RemoteAddr())

		case frAuthUser:
			name, err = verifyAuth(payload, nonce, hub.accounts.Users)
			if err != nil {
				_ = writeFrame(conn, frErr, strPayload(err.Error()))
				break
			}
			role = "viewer"
			authed = true
			_ = writeFrame(conn, frOK, nil)
			log.Printf("viewer logged in: %s (%s)", name, conn.RemoteAddr())

		case frConnectReq:
			if !authed || role != "viewer" {
				_ = writeFrame(conn, frErr, strPayload("not authorized"))
				break
			}
			deviceID, err := readName(payload)
			if err != nil {
				_ = writeFrame(conn, frErr, strPayload(err.Error()))
				break
			}
			hostConn := hub.lookupHost(deviceID)
			if hostConn == nil {
				_ = writeFrame(conn, frErr, strPayload("device offline: "+deviceID))
				break
			}
			sessionID := randomSessionID()
			hub.relay.createSession(sessionID)
			writeCh := make(chan []byte, 8)
			done := make(chan struct{})
			hub.mu.Lock()
			hub.tcpSessions[sessionID] = &tcpSession{hostConn: hostConn, viewerConn: conn, hostDeviceID: deviceID, writeCh: writeCh, done: done}
			hub.sessionByConn[hostConn] = sessionID
			hub.sessionByConn[conn] = sessionID
			hub.mu.Unlock()
			info := make([]byte, 10)
			binary.LittleEndian.PutUint64(info, sessionID)
			binary.LittleEndian.PutUint16(info[8:], uint16(hub.relay.port))
			if err := writeFrame(conn, frSessionInfo, info); err != nil {
				conn.Close()
				continue
			}
			if err := writeFrame(hostConn, frSessionInfo, info); err != nil {
				_ = writeFrame(conn, frErr, strPayload("host unreachable"))
				conn.Close()
				continue
			}
			go func() {
				for {
					select {
					case data := <-writeCh:
						if err := writeFrame(conn, frData, data); err != nil {
							log.Printf("frData forward error (viewer): %v", err)
							conn.Close()
							return
						}
					case <-done:
						return
					}
				}
			}()
			log.Printf("session %d opened: %s -> %s", sessionID, name, deviceID)

		case frData:
			hub.mu.Lock()
			sid, ok := hub.sessionByConn[conn]
			var writeCh chan []byte
			var done <-chan struct{}
			var dst net.Conn
			if ok {
				ts := hub.tcpSessions[sid]
				if ts != nil {
					if ts.hostConn == conn {
						writeCh = ts.writeCh
						done = ts.done
					} else {
						dst = ts.hostConn
					}
				}
			}
			hub.mu.Unlock()
			if writeCh != nil {
				payloadCopy := make([]byte, len(payload))
				copy(payloadCopy, payload)
				select {
				case writeCh <- payloadCopy:
				case <-done:
				}
			} else if dst != nil {
				payloadCopy := make([]byte, len(payload))
				copy(payloadCopy, payload)
				if err := writeFrame(dst, frData, payloadCopy); err != nil {
					log.Printf("frData forward error: %v (dst=%v)", err, dst.RemoteAddr())
				}
			} else {
				log.Printf("frData no dst: sid=%d ok=%v from=%v len=%d", sid, ok, conn.RemoteAddr(), len(payload))
			}

		default:
			// ignore unknown frames for forward compatibility
		}
	}

	if authed && role == "host" {
		hub.unregisterHost(name, conn)
		log.Printf("host device went offline: %s", name)
	}
	hub.mu.Lock()
	if sid, ok := hub.sessionByConn[conn]; ok {
		delete(hub.sessionByConn, conn)
		if ts := hub.tcpSessions[sid]; ts != nil {
			if ts.hostConn == conn {
				ts.hostConn = nil
			} else if ts.viewerConn == conn {
				ts.viewerConn = nil
				ts.writeCh = nil
				close(ts.done)
			}
			if ts.hostConn == nil && ts.viewerConn == nil {
				delete(hub.tcpSessions, sid)
			}
		}
	}
	hub.mu.Unlock()
}

func verifyAuth(payload, nonce []byte, expected map[string]string) (string, error) {
	if len(payload) < 1 {
		return "", fmt.Errorf("malformed auth frame")
	}
	nameLen := int(payload[0])
	if len(payload) < 1+nameLen+32 {
		return "", fmt.Errorf("malformed auth frame")
	}
	name := string(payload[1 : 1+nameLen])
	mac := payload[1+nameLen : 1+nameLen+32]

	password, ok := expected[name]
	if !ok {
		return "", fmt.Errorf("unknown account: %s", name)
	}
	mac2 := hmac.New(sha256.New, authKey(password))
	mac2.Write(nonce)
	if !hmac.Equal(mac, mac2.Sum(nil)) {
		return "", fmt.Errorf("wrong password for %s", name)
	}
	return name, nil
}

func readName(payload []byte) (string, error) {
	if len(payload) < 1 {
		return "", fmt.Errorf("malformed name frame")
	}
	n := int(payload[0])
	if len(payload) < 1+n {
		return "", fmt.Errorf("malformed name frame")
	}
	return string(payload[1 : 1+n]), nil
}

func strPayload(s string) []byte {
	b := []byte(s)
	if len(b) > 255 {
		b = b[:255]
	}
	return append([]byte{byte(len(b))}, b...)
}

func randomSessionID() uint64 {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return binary.LittleEndian.Uint64(b[:])
}

func writeFrame(conn net.Conn, typ uint16, payload []byte) error {
	buf := make([]byte, 6+len(payload))
	binary.LittleEndian.PutUint16(buf, typ)
	binary.LittleEndian.PutUint32(buf[2:], uint32(len(payload)))
	copy(buf[6:], payload)
	_, err := conn.Write(buf)
	return err
}

func readFrame(conn net.Conn) (uint16, []byte, error) {
	hdr := make([]byte, 6)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		return 0, nil, err
	}
	typ := binary.LittleEndian.Uint16(hdr)
	ln := binary.LittleEndian.Uint32(hdr[2:])
	if ln > maxFrameSize {
		return 0, nil, fmt.Errorf("frame too large: %d", ln)
	}
	payload := make([]byte, ln)
	if _, err := io.ReadFull(conn, payload); err != nil {
		return 0, nil, err
	}
	return typ, payload, nil
}
