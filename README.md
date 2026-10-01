# mac_remote

Personal macOS-to-macOS screen sharing with direct LAN/VPN and self-hosted relay
modes. Requires macOS 13+, Screen Recording and Accessibility permission on the
host, and a logged-in macOS GUI session.

**Use a protected network.** Traffic is not encrypted by the application, and
direct LAN mode is unauthenticated. Relay account authentication is not encryption.
Use WireGuard/Tailscale or SSH tunnels before carrying screen contents, keystrokes,
or unlock passwords over the Internet.

See [the deployment guide](docs/DEPLOYMENT.md) for your host at `10.203.14.191`,
the checkout at `/Volumes/mao-data/tools/mac_remote`, and relay `myserver` on
TCP `4430` / UDP `4431`, including an encrypted SSH-only setup.

## Build And Validate

```sh
bash scripts/check.sh
swift build -c release
```

The check script requires Swift Command Line Tools and Go. It builds both apps,
checks route fallback, packet validation, fragment recovery, deferred-tile retry,
idle PNG refinement and pixel diffing, then runs Go relay integration tests with
the race detector. With full Xcode, `swift test` also runs the XCTest route suite.

Native binaries are in `.build/release/`. Build on the target Mac if its CPU
architecture differs. Universal builds require full Xcode:

```sh
swift build -c release --arch arm64 --arch x86_64
```

## Connection Modes

| Mode | Video | Input/control | Protection required |
| --- | --- | --- | --- |
| Direct LAN/VPN | Hardware H.264 or HEVC over UDP | UDP | Trusted LAN or VPN |
| Relay | Compressed tiles with settled PNG refinement | TCP | VPN or SSH tunnel |

Relay video starts on TCP, then prefers verified direct UDP or relayed UDP.
Request/response probes test each UDP route; a route expires after three seconds
without acknowledgment. Both endpoints should run the updated build. TCP-only
networks continue to work if the relay control port is reachable.

### Direct Connection

Host:

```sh
.build/release/mac_remote_host --port 42420 --fps 60 --bitrate 40 --codec hevc
```

Viewer:

```sh
.build/release/mac_remote_client 10.203.14.191 --port 42420
```

### Relay Connection

Deploy with the remote home directory quoted:

```sh
scripts/deploy_relay.sh myserver '~/relay' --control-port 4430 --udp-port 4431
```

Use a relay address reachable through your private VPN, or follow the SSH tunnel
instructions in the deployment guide:

```sh
.build/release/mac_remote_host --relay RELAY_VPN_IP:4430 \
  --device-id office-mac --fps 30 --bitrate 12
.build/release/mac_remote_client --relay RELAY_VPN_IP:4430 \
  --user alice --device-id office-mac
```

Use your existing account names. Passwords are prompted without echo; the apps
also accept `MAC_REMOTE_PASSWORD`. `myserver` may be an SSH-only alias, so it is
not automatically an application-resolvable relay address.

## Quality And Latency

- Relay mode sends 128x128 changed tiles. Motion uses adaptive lossy quality;
  settled tiles are scheduled for lossless PNG refinement after about 300 ms.
- Deferred tiles remain pending and retry with current pixels, including while
  the desktop is idle. Fair rotation prevents later screen areas starving.
- Every pixel row is compared, including single-row text/caret changes. A full
  refresh is scheduled every five seconds to repair unrecovered packet loss.
- `--bitrate` caps relay tile payload traffic as well as configuring LAN video.
  Set it below available bandwidth; overhead and retransmissions are additional.
- Video admission is bounded at 256 KiB in the Swift relay transport. The Go
  relay uses a bounded queue with backpressure instead of silently dropping TCP
  data. OS socket buffers are additional.
- Client tile flushing runs at a 60 Hz timer cadence and drains all pending
  frames with per-tile stale-update filtering.
- Fragment assembly validates metadata, expires incomplete assemblies, and caps
  outstanding fragmented packets. Reconnect resets sockets and route state.

There is no promise of lossless 60 fps on every network. Motion remains lossy,
TCP can stall behind lost packets, and the tile budget does not automatically
measure available link capacity. Hardware video over a private VPN is generally
the better fit for sustained full-screen motion. Live latency and quality still
need validation on your two Macs.

## Service And Controls

Install the host as a per-user LaunchAgent, not a system LaunchDaemon:

```sh
scripts/install_service.sh --binary .build/release/mac_remote_host \
  --port 42420 --fps 60 --bitrate 40 --codec hevc
```

The installer preserves unspecified existing settings, including relay settings.
See the deployment guide before switching an existing service between modes.
The installed app is `~/Library/Application Support/mac_remote/mac_remote_host.app`.
Grant Screen Recording and Accessibility to that app, then restart the service.

| Shortcut | Action |
| --- | --- |
| ESC | Exit viewer |
| Cmd+Shift+D | Switch host display |
| Cmd+Shift+U | Request remote unlock; protected connections only |

No audio, clipboard, file transfer, Keychain integration, built-in encryption,
or per-device viewer authorization is provided. Treat the relay and all its users
as trusted. The relay UDP socket currently requires IPv4.

## Project Layout

- `Sources/MacRemoteCore`: packet protocol, UDP flow, relay routing and transport.
- `Sources/mac_remote_host`: capture, hardware video, tile encoding and input injection.
- `Sources/mac_remote_client`: decoding, rendering and input capture.
- `relayd`: Go authentication, session control and TCP/UDP forwarding.
- `Tests`: focused Swift route tests and Command Line Tools smoke checks.
- `scripts`: deployment, host service management and local verification.
- `docs`: deployment guide and historical wire-protocol references.
