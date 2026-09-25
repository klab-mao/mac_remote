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

> Plain `swift build` produces an arm64-only binary — Intel Macs reject it with `bad CPU type in executable`. Always use `--arch arm64 --arch x86_64`.

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
.build/out/Products/Debug/mac_remote_host [--port 42420] [--fps 60] [--bitrate 25] [--display 0]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--port` | 42420 | UDP port |
| `--fps` | 60 | capture/encode framerate |
| `--bitrate` | 25 | H.264 bitrate in Mbps (use 40-80 on LAN for near-lossless text) |
| `--display` | 0 | initial display index (use `--display 1` for second monitor) |

The host enumerates all displays at startup and prints them:
```
Available displays: 2
  [0] id=3 2560x1440 origin=(0,0)
  [1] id=1 2560x1440 origin=(2560,0)
```

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

When switching displays, an overlay shows `Display X / Y` for ~2.5 seconds. The host reconfigures the encoder if the new display has a different resolution and forces a keyframe.

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
- Auto-reconnect + persistent connection.
- LaunchDaemon / menu-bar app packaging for the host.
