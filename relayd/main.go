package main

import (
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
)

// Accounts maps names to passwords. Users are viewers, Hosts are controlled devices.
type Accounts struct {
	Users map[string]string `json:"users"`
	Hosts map[string]string `json:"hosts"`
}

func loadAccounts(path string) (*Accounts, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var a Accounts
	if err := json.Unmarshal(data, &a); err != nil {
		return nil, err
	}
	if a.Users == nil {
		a.Users = map[string]string{}
	}
	if a.Hosts == nil {
		a.Hosts = map[string]string{}
	}
	return &a, nil
}

// authKey derives the HMAC key from a password (sha256).
func authKey(password string) []byte {
	h := sha256.Sum256([]byte(password))
	return h[:]
}

func main() {
	ctrlPort := flag.Int("control", 42430, "TCP control port")
	udpPort := flag.Int("udp", 42431, "UDP relay data port")
	cfgPath := flag.String("config", "accounts.json", "accounts JSON file")
	hash := flag.String("hash", "", "print auth key (sha256 hex) of a password and exit")
	flag.Parse()

	if *hash != "" {
		fmt.Printf("%x\n", authKey(*hash))
		return
	}

	accounts, err := loadAccounts(*cfgPath)
	if err != nil {
		log.Fatalf("load %s: %v", *cfgPath, err)
	}
	log.Printf("accounts loaded: %d users, %d host devices", len(accounts.Users), len(accounts.Hosts))

	relay, err := newUDPRelay(*udpPort)
	if err != nil {
		log.Fatalf("udp relay: %v", err)
	}
	go relay.run()
	go relay.cleanupLoop()

	ln, err := net.Listen("tcp", fmt.Sprintf(":%d", *ctrlPort))
	if err != nil {
		log.Fatalf("tcp listen: %v", err)
	}
	log.Printf("relayd listening: control tcp/:%d, data udp/:%d", *ctrlPort, *udpPort)

	hub := &controlHub{
		accounts: accounts,
		relay:    relay,
		hosts:    map[string]net.Conn{},
	}

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go handleControl(conn, hub)
	}
}
