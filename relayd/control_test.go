package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"net"
	"testing"
	"time"
)

func authFrame(name, password string, nonce []byte) []byte {
	mac := hmac.New(sha256.New, authKey(password))
	mac.Write(nonce)
	p := append([]byte{byte(len(name))}, []byte(name)...)
	return append(p, mac.Sum(nil)...)
}

func TestControlAuthFlow(t *testing.T) {
	accounts := &Accounts{
		Users: map[string]string{"alice": "pw1"},
		Hosts: map[string]string{"dev1": "pw2"},
	}
	relay, err := newUDPRelay(0)
	if err != nil {
		t.Fatal(err)
	}
	go relay.run()
	hub := &controlHub{accounts: accounts, relay: relay, hosts: map[string]net.Conn{}}

	clientConn, serverConn := net.Pipe()
	go handleControl(serverConn, hub)

	typ, payload, err := readFrame(clientConn)
	if err != nil {
		t.Fatal(err)
	}
	if typ != frChallenge || len(payload) != 32 {
		t.Fatalf("want challenge(32B), got type=%d len=%d", typ, len(payload))
	}

	writeFrame(clientConn, frAuthUser, authFrame("alice", "pw1", payload))
	typ, _, err = readFrame(clientConn)
	if err != nil {
		t.Fatal(err)
	}
	if typ != frOK {
		t.Fatalf("want ok after valid login")
	}

	writeFrame(clientConn, frConnectReq, append([]byte{4}, []byte("dev1")...))
	typ, payload, err = readFrame(clientConn)
	if err != nil {
		t.Fatal(err)
	}
	if typ != frErr {
		t.Fatalf("want err for offline device, got %d", typ)
	}
	if !bytes.Contains(payload, []byte("offline")) {
		t.Fatalf("err payload should mention offline: %s", payload)
	}

	badConn, badServer := net.Pipe()
	go handleControl(badServer, hub)
	_, nonce, _ := readFrame(badConn)
	writeFrame(badConn, frAuthUser, authFrame("alice", "wrong", nonce))
	typ, _, err = readFrame(badConn)
	if err != nil {
		t.Fatal(err)
	}
	if typ != frErr {
		t.Fatalf("want err for wrong password, got %d", typ)
	}
}

func TestHostRegisterAndSession(t *testing.T) {
	accounts := &Accounts{
		Users: map[string]string{"alice": "pw1"},
		Hosts: map[string]string{"dev1": "pw2"},
	}
	relay, err := newUDPRelay(0)
	if err != nil {
		t.Fatal(err)
	}
	go relay.run()
	hub := &controlHub{accounts: accounts, relay: relay, hosts: map[string]net.Conn{}}

	hostConn, hostServer := net.Pipe()
	go handleControl(hostServer, hub)
	_, nonce, _ := readFrame(hostConn)
	writeFrame(hostConn, frAuthHost, authFrame("dev1", "pw2", nonce))
	typ, _, _ := readFrame(hostConn)
	if typ != frOK {
		t.Fatalf("host auth failed")
	}

	viewerConn, viewerServer := net.Pipe()
	go handleControl(viewerServer, hub)
	_, vnonce, _ := readFrame(viewerConn)
	writeFrame(viewerConn, frAuthUser, authFrame("alice", "pw1", vnonce))
	typ, _, _ = readFrame(viewerConn)
	if typ != frOK {
		t.Fatalf("viewer auth failed")
	}

	writeFrame(viewerConn, frConnectReq, append([]byte{4}, []byte("dev1")...))
	typ, payload, err := readFrame(viewerConn)
	if err != nil {
		t.Fatal(err)
	}
	if typ != frSessionInfo || len(payload) != 10 {
		t.Fatalf("viewer want sessionInfo, got %d", typ)
	}
	typ, hpayload, err := readFrame(hostConn)
	if err != nil {
		t.Fatal(err)
	}
	if typ != frSessionInfo || len(hpayload) != 10 {
		t.Fatalf("host want sessionInfo, got %d", typ)
	}
	if !bytes.Equal(payload, hpayload) {
		t.Fatalf("session info mismatch between sides")
	}
}

func TestUDPRelayForwarding(t *testing.T) {
	relay, err := newUDPRelay(0)
	if err != nil {
		t.Fatal(err)
	}
	go relay.run()
	relayAddr := relay.conn.LocalAddr().(*net.UDPAddr)

	relay.createSession(42)

	hostSock, err := net.DialUDP("udp", nil, relayAddr)
	if err != nil {
		t.Fatal(err)
	}
	clientSock, err := net.DialUDP("udp", nil, relayAddr)
	if err != nil {
		t.Fatal(err)
	}

	bind := func(sock *net.UDPConn, side byte) {
		b := make([]byte, 13)
		copy(b, bindMagic)
		binary.LittleEndian.PutUint64(b[4:], 42)
		b[12] = side
		if _, err := sock.Write(b); err != nil {
			t.Fatal(err)
		}
		time.Sleep(100 * time.Millisecond)
	}
	bind(hostSock, bindSideHost)
	bind(clientSock, bindSideClient)

	if _, err := hostSock.Write([]byte("video-frame")); err != nil {
		t.Fatal(err)
	}
	clientSock.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 128)
	n, _, err := clientSock.ReadFromUDP(buf)
	if err != nil {
		t.Fatalf("client did not receive forwarded packet: %v", err)
	}
	if string(buf[:n]) != "video-frame" {
		t.Fatalf("unexpected payload: %q", buf[:n])
	}

	if _, err := clientSock.Write([]byte("input-event")); err != nil {
		t.Fatal(err)
	}
	hostSock.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, _, err = hostSock.ReadFromUDP(buf)
	if err != nil {
		t.Fatalf("host did not receive forwarded packet: %v", err)
	}
	if string(buf[:n]) != "input-event" {
		t.Fatalf("unexpected payload: %q", buf[:n])
	}
}
