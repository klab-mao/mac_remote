# mac_remote

Internal-use macOS screen sharing tool (macOS-to-macOS), built as a replacement for the slow built-in Screen Sharing (VNC). Goal: TeamViewer-level smoothness with visually lossless image quality.

## Architecture

```
Host (controlled Mac)                         Client (viewing Mac)
---------------------                         --------------------
ScreenCaptureKit (GPU capture, 60fps)
        |
VideoToolbox H.264 hardware encoder
(realtime, no B-frames, zero frame delay)
        |
Fragmented UDP datagrams (1300B)  --------->  Frame reassembly
        |                                        |
        |                                  AVSampleBufferDisplayLayer
        |                                  (hardware decode + render)
        |                                        |
        +----- input events (UDP) <----------  NSEvent local monitor
                                                  (mouse/keyboard/scroll)
Host: CGEvent.post(tap: .cghidEventTap)       Client: borderless fullscreen window
```

### Key design choices

- **ScreenCaptureKit** — GPU-accelerated capture at full retina resolution (macOS 12.3+). Zero-copy IOSurface pixel buffers passed directly to the encoder.
- **VideoToolbox H.264** — Apple media engine hardware encode/decode. Configured for minimal latency: `RealTime=true`, `AllowFrameReordering=false`, `MaxFrameDelayCount=0`, `ProfileLevel=High_AutoLevel`.
- **UDP transport** — no retransmission (real-time). Frames fragmented into 1300-byte datagrams. Keyframe requested on connect and on decode failure.
- **SPS/PPS out-of-band** — parameter sets sent as control packets on keyframes; client builds `CMVideoFormatDescription` and feeds AVCC NALUs directly to `AVSampleBufferDisplayLayer`.
- **Normalized input coordinates** — mouse position sent as 0.0-1.0 normalized within the captured display, mapped to global CG coordinates on the host. Retina scaling and multi-monitor offsets handled transparently.
- **Separate input channel** — input events share the UDP connection but use distinct packet types, keeping them low-latency and independent of video frame timing.

## Project structure

```
mac_remote/
  Package.swift                    Swift package (platforms: macOS 13+)
  Sources/
    MacRemoteCore/                 Shared library
      Protocol.swift               Packet header, types, InputPacket, Packetizer
      Transport.swift              UDPFlow (NWConnection), UDPListener (NWListener)
    mac_remote_host/               Host executable (the controlled Mac)
      main.swift                   HostEngine: lifecycle, flow handling, arg parsing
      Capture.swift                CaptureEngine: SCStream multi-display + switching
      Encoder.swift                H264Encoder: VTCompressionSession wrapper
      InputInjector.swift          CGEvent mouse/keyboard/scroll injection
    mac_remote_client/             Client executable (the viewing Mac)
      main.swift                   ClientDelegate: window, streamer, timers
      Streamer.swift               Frame reassembly, sample buffer creation, decode
      InputSender.swift            VideoView, BorderlessWindow, NSEvent monitor
```

## Build

```sh
swift build --arch arm64 --arch x86_64
```

Produces a **universal (fat) binary** so the same executables run on both Apple Silicon and Intel Macs. The x86_64 slice targets macOS 13 (Ventura) minimum.

> Plain `swift build` on Apple Silicon produces an arm64-only binary — Intel Macs reject it with `bad CPU type in executable`. Always use `--arch arm64 --arch x86_64`.
>
> Universal builds require full Xcode (multi-arch builds go through `xcbuild`). With only Command Line Tools installed, `--arch` builds fail — build for the native architecture instead: `swift build -c release`.

Binaries land in `.build/out/Products/Debug/`.

## Permissions (required on the HOST Mac)

The host needs two permissions. Run it once from the terminal, then grant:

1. **Screen Recording** — System Settings > Privacy & Security > Screen Recording: enable the binary (or Terminal). Required for ScreenCaptureKit.
2. **Accessibility** — System Settings > Privacy & Security > Accessibility: enable the same. Required for `CGEvent.post` (mouse/keyboard injection). Without it, video works but clicks/keys silently do nothing.

Restart the host after granting. The client needs no special permissions.

The host prints permission status at startup:
```
Screen Recording permission: GRANTED
Accessibility permission: GRANTED
```

## Usage

### Host (the Mac being controlled)

```sh
.build/out/Products/Debug/mac_remote_host [--port 42420] [--fps 60] [--bitrate 25] [--display 0] [--client-timeout 10]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--port` | 42420 | UDP port |
| `--fps` | 60 | capture/encode framerate |
| `--bitrate` | 25 | H.264 bitrate in Mbps (use 40-80 on LAN for near-lossless text) |
| `--display` | 0 | initial display index (use `--display 1` for second monitor) |
| `--client-timeout` | 10 | seconds without client packets before stopping video (0 = never timeout) |

The host enumerates all displays at startup and prints them:
```
Available displays: 2
  [0] id=3 2560x1440 origin=(0,0)
  [1] id=1 2560x1440 origin=(2560,0)
```

### Run the host as a service (launchd)

`scripts/install_service.sh` installs the host as a **per-user LaunchAgent** that starts at login and is restarted on crash. A system LaunchDaemon would not work: ScreenCaptureKit can only capture from a logged-in GUI session, and TCC permissions (Screen Recording / Accessibility) are granted per user.

```sh
scripts/install_service.sh [--port 42420] [--fps 60] [--bitrate 25] [--display 0] [--client-timeout 10] [--binary PATH]
```

It builds a universal Release binary if none exists (falling back to a native-arch Release build on machines with only Command Line Tools, where universal builds are unavailable), copies it to `~/Library/Application Support/mac_remote/bin/mac_remote_host`, writes `~/Library/LaunchAgents/com.mac_remote.host.plist`, and loads it. Re-running replaces the service with the new settings. Log: `~/Library/Application Support/mac_remote/host.log`.

```sh
launchctl list com.mac_remote.host                           # status
launchctl kickstart -k gui/$(id -u)/com.mac_remote.host      # restart
tail -f "$HOME/Library/Application Support/mac_remote/host.log"
scripts/uninstall_service.sh                                 # stop + remove everything
```

TCC permissions are bound to the binary **path**: after installing, grant Screen Recording and Accessibility to the installed copy (`~/Library/Application Support/mac_remote/bin/mac_remote_host`) — not the build output — then restart the service and check the log for `permission: GRANTED`.

### Client (the Mac viewing/controlling)

```sh
.build/out/Products/Debug/mac_remote_client <host-ip> [--port 42420]
```

The client opens a borderless fullscreen window (level: floating, activation policy: regular). Mouse, scroll wheel, keyboard (with modifiers), and drag events are forwarded to the host.

### Hotkeys

| Key | Action |
|-----|--------|
| **ESC** | Quit the client |
| **Cmd+Shift+D** | Cycle to the next display on the host |
| **Cmd+Shift+U** | Unlock the remote Mac's lock screen (prompts for password) |

When switching displays, an overlay shows `Display X / Y` for ~2.5 seconds. The host reconfigures the encoder if the new display has a different resolution and forces a keyframe.

### Screen lock / unlock

The host watches `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` distributed notifications and reports lock state changes to the client (shown as a transient overlay).

To unlock a locked remote Mac, press **Cmd+Shift+U** on the client, enter the host's login password, and confirm. The host then:

1. Wakes the displays (power assertion + mouse nudge),
2. Types the password into the loginwindow password field via synthetic CGEvents (US ANSI key mapping), and presses Return,
3. Verifies the result by polling the session lock state (`CGSessionCopyCurrentDictionary`) for up to 3s and reports a result code back to the client.

**Limitations:**

- **Secure Event Input** — macOS may block synthetic keyboard events from reaching the loginwindow password field (this is an intentional security hardening). The host self-verifies and the client shows `Unlock failed — still locked` if it didn't work. In that case, unlock once physically. There is no supported way for a non-privileged process to bypass Secure Input.
- **Password characters are limited to the US ANSI printable set** (letters, digits, common punctuation). Passwords with other characters are rejected with a clear message rather than typed incorrectly.
- **The password travels unencrypted over UDP** in cleartext — this tool is designed for trusted LAN/VPN use only.
- Apple Watch / Touch ID unlock cannot be triggered remotely.

## Protocol

### Packet header (16 bytes, little-endian)

```
[1] version    (always 1)
[1] type       (0=video, 1=input, 2=control)
[1] flags      (video: bit 0 = keyframe)
[1] reserved
[4] frameId
[2] fragIndex
[2] fragCount
[4] payloadLength
```

### Control subtypes

| Value | Name | Direction | Payload |
|-------|------|-----------|---------|
| 0 | hello | client→host | — |
| 1 | helloAck | host→client | — |
| 2 | params | host→client | SPS + PPS (out-of-band) |
| 3 | keyframeRequest | client→host | — |
| 4 | switchDisplay | client→host | display index (255 = cycle next) |
| 5 | displayInfo | host→client | current index, total count |
| 6 | unlockRequest | client→host | password (UTF-8) |
| 7 | unlockResult | host→client | result code (0=unlocked, 1=notLocked, 2=stillLocked, 3=unsupportedCharacter, 4=error) |
| 8 | lockState | host→client | 1 = locked, 0 = unlocked |

### Input packet (28 bytes)

```
[1] kind        (0=mouseMove, 1=mouseDown, 2=mouseUp, 3=scroll, 4=keyDown, 5=keyUp, 6=flagsChanged)
[1] button      (0=left, 1=right, 2=middle)
[2] keyCode     (CGKeyCode)
[4] flags       (CGEventFlags, device-independent mask)
[4] nx          (normalized X, 0.0-1.0, top-left origin)
[4] ny          (normalized Y, 0.0-1.0, top-left origin)
[4] dx          (scroll delta X)
[4] dy          (scroll delta Y)
[4] clickCount
```

## Diagnostics

Both sides print diagnostic logs for the first few events to help troubleshoot:

**Host:**
```
Encoder setup: 2560x1440 40Mbps...
Encoder ready: 2560x1440 40Mbps H.264 HW
encoded #1: 307157 bytes, keyframe=true, frags=237
input #1: kind=mouseDown button=0 nx=0.5 ny=0.5 -> global (1280,720)
```

**Client:**
```
Format ready: 2560x1440
monitor saw leftMouseDown: ... match=true isKey=true
input captured #1: kind=mouseDown button=0 nx=0.5 ny=0.5
fps: 60
```

If clicks aren't working, check:
1. Host prints `Accessibility permission: GRANTED` — if not, grant it and restart.
2. Host prints `input #1:` lines — if not, the client isn't sending (check client log).
3. Client prints `input captured #1:` — if not, `normalizedPoint` is returning nil (check for `normalizedPoint nil:` log showing zero bounds/remoteSize).
4. Client prints `displayLayer FAILED` — video decode layer failed, will request keyframe.

## Disconnect / reconnect

### Client timeout (bandwidth saving)

The host tracks the last time a packet was received from the client. If no packet arrives within `--client-timeout` seconds (default 10), the host stops sending video frames and logs:

```
Client inactive for 12s — stopping video (timeout=10s)
```

The capture engine keeps running (for fast resume), but no network traffic is generated. When the client sends any packet again (hello, input, keyframe request), the host immediately resumes:

```
Client reconnected, resuming video
```

The client continuously sends hello + keyframe requests every 0.5s as a heartbeat, so the host can detect reconnection within 1 second.

### VPN disconnect

If a company VPN drops mid-session:

1. **UDP packets are lost** — neither side receives the other's packets while the VPN is down.
2. **Host stops sending** after `--client-timeout` seconds of no client packets.
3. **Client detects no video** after 5s and logs `No video for 5s — reconnecting (sending hello...)`.
4. **When VPN resumes**, the client's heartbeat hello packets reach the host again, the host resumes sending, and the client logs `Reconnected — video resumed`.

No manual restart is needed. The connection self-heals as long as the VPN comes back. If the VPN is down longer than the host's timeout, there may be a brief delay (1-2s) while the host waits for a keyframe request before resuming.

### Single-display bandwidth

The host only captures and sends **one display at a time** — the one the client is currently viewing. Switching displays (Cmd+Shift+D) tells the host to stop capturing the old display and start capturing the new one. No bandwidth is wasted on displays the client isn't viewing.

## Known issues

- **Video may stall after initial frames** — `AVSampleBufferDisplayLayer` can fail after a few frames, possibly due to large keyframe fragment loss on UDP or sample buffer timing. The client detects `.failed` status, flushes, and requests a keyframe. Under investigation.
- **Single viewer at a time** — latest `hello` wins; a second client replaces the first.
- **No retransmission/FEC** — on lossy Wi-Fi, frames may drop until the next keyframe (2s interval). On a clean LAN with high `--bitrate`, loss is rare.
- **Remote cursor drawn into video** — the host's physical cursor is captured in the frame; the local cursor is hidden over the client window.
- **No audio streaming, no clipboard sync, no file transfer.**

## Roadmap

- Fix video stalling — investigate `AVSampleBufferDisplayLayer` failure cause; consider FEC for large keyframes.
- Adaptive bitrate based on packet loss / RTT (ping packet type reserved in protocol).
- HEVC/AV1 encode option (VideoToolbox supports both on Apple Silicon).
- Clipboard sync channel.
- Pause capture engine (not just skip send) when client times out, to save CPU.
- LaunchDaemon / menu-bar app packaging for the host.
