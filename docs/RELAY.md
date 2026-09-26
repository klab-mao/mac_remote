# Relay Mode: Bridging Two Intranets via a Cloud Server

When the client and host Macs are on different networks (both behind NAT), direct UDP is impossible. Relay mode routes both sides through your own cloud server, so **both intranets are bridged with outbound-only connections** — no port forwarding, no router changes.

## Architecture

```
Host Mac (intranet A)                Cloud Server (relayd)                Client Mac (intranet B)
---------------------                ---------------------                ----------------------
mac_remote_host                                            mac_remote_client
  --relay R:42430   --TCP control (auth/register)-->   :42430      <--TCP control (login/request)--  --user alice --device-id X
        |                                                  |                                        |
        +--------- UDP data (bind + video) -------------> :42431  <--UDP data (bind + input) ---------+
                        all packets relayed by sessionId, bidirectional
```

1. **Host** connects OUT to relayd over TCP, authenticates as a device (`challenge → HMAC → ok`), registers its device-id.
2. **Client** connects OUT, logs in with a user account (same HMAC challenge-response), then requests a device-id.
3. If the device is online, relayd creates a **session** (random 64-bit id) and sends `sessionInfo {sessionId, udpPort}` to both sides.
4. Both sides open UDP to the relay data port and send a **bind** frame (`RMBD` magic + sessionId + side). relayd records their endpoints.
5. From then on, every UDP datagram from either endpoint is forwarded to the other — the existing video/input/control packet protocol flows unchanged inside.

Both sides only make **outbound** connections, so this works across NAT in any network topology. Trade-off: traffic passes through the cloud server (latency ≈ RTT to server; bandwidth = the video bitrate, ~5 MB/s at 40 Mbps — size your VPS accordingly).

## Why HMAC challenge-response

The password never crosses the wire. The server sends a random 32-byte nonce; the client answers with `HMAC-SHA256(key=SHA256(password), nonce)`. Replay is defeated by the per-connection nonce. Accounts are configured server-side only.

## Server: build & configure

Requirements: Go 1.21+ on the cloud server (any Linux).

```sh
cd relayd
go build -o relayd .
```

`accounts.json` (place next to the binary; `chmod 600`):

```json
{
  "users": { "alice": "strong-password-1" },
  "hosts": { "office-mac": "strong-password-2" }
}
```

- `users` — client login accounts (viewers)
- `hosts` — controlled Mac devices, keyed by device-id

Run:

```sh
./relayd -control 42430 -udp 42431 -config accounts.json
```

Flags: `-control` TCP control port (default 42430), `-udp` UDP data port (default 42431), `-hash <pw>` prints the SHA-256 auth key (helper), `-config` accounts path.

### systemd unit

```ini
# /etc/systemd/system/relayd.service
[Unit]
Description=mac_remote relay
After=network.target

[Service]
ExecStart=/opt/mac_remote/relayd -control 42430 -udp 42431 -config /opt/mac_remote/accounts.json
Restart=always
User=nobody
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl enable --now relayd
```

### Firewall

Open inbound: **TCP 42430** and **UDP 42431** (adjust to your flags). Example for ufw: `ufw allow 42430/tcp && ufw allow 42431/udp`.

## Host Mac (controlled side)

```sh
mac_remote_host --relay relay.example.com:42430 --device-id office-mac --password strong-password-2
```

Or set `MAC_REMOTE_PASSWORD` in the environment instead of `--password` (avoids the password in `ps` output). All LAN flags (`--fps`, `--bitrate`, `--display`, `--client-timeout`, `--debug`) still apply. When `--relay` is given, the LAN listener is not started.

## Client Mac (viewing side)

```sh
mac_remote_client --relay relay.example.com:42430 --user alice --device-id office-mac
```

Password is prompted with echo disabled (or use `--password` / `MAC_REMOTE_PASSWORD` for non-interactive use). LAN mode still works: `mac_remote_client <host-ip>` with no `--relay`.

## Protocol reference (control channel, TCP)

Frame: `[u16 type LE][u32 len LE][payload]`

| Type | Name | Direction | Payload |
|------|------|-----------|---------|
| 1 | challenge | S→C | 32-byte nonce |
| 2 | authHost | C→S | [u8 idLen][device-id][32B HMAC] |
| 3 | authUser | C→S | [u8 nameLen][username][32B HMAC] |
| 4 | ok | S→C | — |
| 5 | err | S→C | [u8 len][message] |
| 6 | connectReq | C→S | [u8 len][device-id] |
| 7 | sessionInfo | S→C | [u64 sessionId LE][u16 udpPort LE] |
| 8/9 | ping/pong | both | — |

UDP data port bind frame: `RMBD` magic (4B) + sessionId (u64 LE) + side (1=host, 2=client). All other datagrams are forwarded verbatim between the session's two endpoints.

## Security notes

- Passwords live in `accounts.json` on the server — `chmod 600`, strong passwords, SSH-key-only server access.
- Video/input data is **not encrypted** end-to-end. It crosses the public internet between your intranets and the relay. For sensitive use, add WireGuard between the Macs and the relay (relayd then bridges inside the encrypted tunnel), or extend the protocol with DTLS/QUIC.
- Only one viewer per host at a time; a new `connectReq` creates a new session.