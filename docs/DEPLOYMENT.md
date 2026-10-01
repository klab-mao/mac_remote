# Personal Screen Sharing Deployment

## Your Environment

- Host SSH address: `10.203.14.191`
- Host checkout: `/Volumes/mao-data/tools/mac_remote`
- Relay SSH alias: `myserver`
- Relay directory: `~/relay` on the relay server
- Relay ports: TCP `4430`, UDP `4431`

`myserver` is an SSH alias, not necessarily a DNS name that the applications
can resolve. For a direct relay connection, use the relay's reachable IP or DNS
name. For the SSH tunnel below, the alias is sufficient.

## Security First

The application does **not** encrypt screen pixels, input, or unlock passwords.
Relay HMAC authentication verifies an account but does not encrypt its session.
LAN mode has no application-level authentication. Any authenticated relay user
can currently request any registered host; there are no per-device user ACLs.

Use a trusted LAN, a private WireGuard/Tailscale network, or the SSH tunnels below.
Do not expose the host's UDP port to the public Internet. Do not send a Mac login
password through an unprotected relay connection. Protect relay accounts with
strong, unique passwords; only use a relay server you trust with screen contents.

## Build And Check

On the development Mac:

```sh
bash scripts/check.sh
swift build -c release
```

The check script builds both apps, tests route failover and real tile encoding
without requiring XCTest, and runs Go tests with the race detector. Full Xcode
also supports `swift test` for the XCTest route suite. Command Line Tools alone
may report `no such module 'XCTest'`.

Native binaries are `.build/release/mac_remote_host` and
`.build/release/mac_remote_client`. Build on the destination Mac when its CPU
architecture differs. With full Xcode, a universal build is available:

```sh
swift build -c release --arch arm64 --arch x86_64
swift build -c release --arch arm64 --arch x86_64 --show-bin-path
```

The second command reports the universal binary output directory.

## No Relay: LAN Or Private VPN

Connect to the host and update its checkout with the reviewed changes:

```sh
ssh 10.203.14.191
cd /Volumes/mao-data/tools/mac_remote
swift build -c release
```

The installer preserves unspecified options from an existing service. **If the
existing service is configured for relay mode, uninstall it before installing
LAN mode.** This removes the installed service and its saved settings; retain
any settings you need first:

```sh
scripts/uninstall_service.sh
```

Install the native build:

```sh
scripts/install_service.sh --binary .build/release/mac_remote_host \
  --port 42420 --fps 60 --bitrate 40 --codec hevc
```

Grant Screen Recording and Accessibility to the installed `mac_remote_host.app`
in System Settings > Privacy & Security. The app is under
`~/Library/Application Support/mac_remote/`. A logged-in GUI session is required;
an SSH session alone cannot provide a capturable desktop.

On the viewing Mac:

```sh
.build/release/mac_remote_client 10.203.14.191 --port 42420
```

Across a VPN, substitute the host's VPN IP. UDP `42420` must be reachable through
that private network. LAN mode uses hardware H.264/HEVC, not the relay tile path.
HEVC at higher bitrates is useful for text, but is not mathematically lossless.

## With Your Relay

Deploy the updated Go relay from the development Mac:

```sh
scripts/deploy_relay.sh myserver '~/relay' --control-port 4430 --udp-port 4431
```

**Quote `~/relay`.** Without quotes, your local shell expands it to the local
Mac's home directory before the deployment script runs. Check the existing
service's directory before changing a previously deployed installation.

The script installs/restarts a systemd service and adjusts the firewall. It
requires server-side sudo access and preserves an existing accounts file in the
selected directory. Use the existing device ID and viewer username below;
`office-mac` and `alice` are examples, not new accounts.

### Protected UDP Relay

Use the relay's private VPN address so that both TCP and UDP are protected.
On the host, in `/Volumes/mao-data/tools/mac_remote`:

```sh
swift build -c release
.build/release/mac_remote_host --relay RELAY_VPN_IP:4430 \
  --device-id office-mac --fps 30 --bitrate 12
```

On the viewing Mac:

```sh
.build/release/mac_remote_client --relay RELAY_VPN_IP:4430 \
  --user alice --device-id office-mac
```

The foreground apps prompt for their respective relay account passwords.
For unattended operation, use `scripts/install_service.sh` with
`--binary .build/release/mac_remote_host` and the same host flags, supplying
`MAC_REMOTE_PASSWORD` locally. The current installer stores relay credentials
in the LaunchAgent configuration; it does not use Keychain.

### Encrypted TCP-Only Relay Through SSH

On **each Mac**, keep this SSH tunnel running in a separate terminal:

```sh
ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -L 127.0.0.1:14430:127.0.0.1:4430 myserver
```

Both Macs need SSH access to `myserver`. The tunnel encrypts each Mac-to-relay
connection. This is not end-to-end encryption against the relay itself.

Host:

```sh
cd /Volumes/mao-data/tools/mac_remote
.build/release/mac_remote_host --relay 127.0.0.1:14430 \
  --device-id office-mac --fps 30 --bitrate 8
```

Viewer:

```sh
.build/release/mac_remote_client --relay 127.0.0.1:14430 \
  --user alice --device-id office-mac
```

SSH forwards only TCP. Since no UDP relay is listening locally at `4431`, UDP
probes fail and video stays on the authenticated TCP relay channel. This also
works on networks that permit SSH but block UDP. Keep both tunnels running for
the whole session; automatic tunnel supervision is not installed by this project.

## What Adapts Automatically

1. Relay sessions start with TCP video, so blocked UDP does not prevent viewing.
2. Session-bound request/response probes test both relayed and direct UDP.
3. Confirmed direct UDP is preferred, then relayed UDP, then TCP. A UDP route
   expires after three seconds without a successful probe acknowledgment.
4. Relay input and application control always use TCP. Route changes are logged
   as `video route: direct UDP`, `video route: UDP relay`, or `video route: TCP relay`.
5. Motion uses compressed tiles. After a region settles for about 300 ms, the
   host schedules lossless PNG refinement. A 100 ms idle timer continues pending
   work even without new capture frames. Completion depends on available bandwidth.
6. Unsent tiles remain pending; retries use current pixels. Accepted video in the
   Swift transport is capped at 256 KiB, and the relay's queue holds eight frames.
   These limits do not include operating-system TCP buffers.

`--bitrate` now sets the relay tile payload budget in Mbps, with a short burst
allowance. It is not a measured-link congestion controller and excludes protocol
overhead and retransmissions. Start below the slowest link's sustained upload
capacity; try 5-8 Mbps on constrained links, 12-20 Mbps on broadband, and raise it
only after observing latency. Lower `--fps` to 30 for a busy or older host.

Stationary refinement preserves rendered tile pixels using PNG; it is not an
HDR/color-management guarantee. Sustained motion remains lossy. Full-resolution
60 fps plus lossless motion on a slow link is not a realistic guarantee.

## Verify On Your Macs

- Install matching new host/client builds. Older clients do not answer the new
  UDP probes; upgrade both ends to enable automatic UDP route selection.
- Test typing, dragging, scrolling, display switching, and reconnecting after a
  Wi-Fi change. For UDP failure testing, use the SSH-only connection above.
- Stop scrolling on dense text and confirm it sharpens as PNG refinements arrive.
- Compare 30 and 60 fps at the same bitrate; watch input latency, not only FPS.
- Restart the relay and verify that both apps reconnect. Network behavior and
  macOS permissions must be checked on the real machines, not just unit tests.

Service diagnostics on the host:

```sh
launchctl list com.mac_remote.host
launchctl kickstart -k gui/$(id -u)/com.mac_remote.host
tail -n 80 "$HOME/Library/Application Support/mac_remote/host.log"
```

ESC exits the viewer; Cmd+Shift+D switches displays; Cmd+Shift+U requests unlock.
Unlock is only appropriate on a protected connection and retains the existing
macOS input/security limitations. Audio, clipboard, file transfer, Internet-grade
authorization, and built-in encryption are not implemented.
