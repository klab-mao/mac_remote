# mac_remote

Internal-use macOS screen sharing tool (macOS-to-macOS), built as a replacement for the slow built-in Screen Sharing (VNC). Goal: TeamViewer-level smoothness with visually lossless image quality.

## Architecture

```
Host (controlled Mac)                    Client (viewing Mac)
---------------------                    --------------------
ScreenCaptureKit (GPU capture, 60fps)
        |
VideoToolbox H.264 hardware encoder
(30Mbps default, no B-frames, zero delay)
        |
Fragmented UDP datagrams (1300B)  ----->  Frame reassembly
                                          |
                                    AVSampleBufferDisplayLayer
                                    (hardware decode + Metal render)
        ^                                        |
        +------ input events (UDP) <-- mouse/keyboard/scroll capture
```

Key design choices:
- **ScreenCaptureKit**: GPU-accelerated capture at full retina resolution (macOS 12.3+).
- **VideoToolbox H.264**: Apple media engine hardware encode/decode; `RealTime` + `AllowFrameReordering=false` + `MaxFrameDelayCount=0` for minimal latency.
- **UDP transport**: no retransmission (real-time), keyframe request on packet loss / session start.
- SPS/PPS parameter sets are delivered out-of-band; the client builds a `CMVideoFormatDescription` and feeds AVCC NALUs directly to `AVSampleBufferDisplayLayer`.
- Input coordinates are normalized (0-1), so retina pixel scaling is handled transparently.

## Build

```sh
swift build --arch arm64 --arch x86_64
```

Build a universal (fat) binary so the same executables run on both Apple Silicon and Intel Macs. The x86_64 slice targets macOS 13 (Ventura) minimum. (Plain `swift build` produces an arm64-only binary — Intel Macs reject it with `bad CPU type in executable`.)

Binaries land in `.build/out/Products/Debug/`.

## Permissions (required on the HOST Mac)

Run the binaries from a terminal app once so macOS can attribute the permission prompts, then grant:

1. **Screen Recording** — System Settings > Privacy & Security > Screen Recording: enable the terminal/app that runs `mac_remote_host`.
2. **Accessibility** — System Settings > Privacy & Security > Accessibility: enable the same, so input can be injected with `CGEvent`.

Restart the host after granting. The client needs no special permissions.

## Usage

Host (the Mac being controlled):

```sh
.build/out/Products/Debug/mac_remote_host [--port 42420] [--fps 60] [--bitrate 25] [--display 0]
```

- `--port` UDP port (default 42420)
- `--fps` capture/encode framerate (default 60)
- `--bitrate` H.264 bitrate in Mbps (default 25; use 40-80 on LAN for near-lossless text sharpness)
- `--display` display index if multiple monitors (default 0)

Client (the Mac viewing/controlling):

```sh
.build/out/Products/Debug/mac_remote_client <host-ip> [--port 42420]
```

Controls: the client window goes borderless fullscreen. Mouse, scroll wheel, keyboard (with modifiers), and drag events are forwarded to the host. Hotkeys:

- **ESC** — quit the client
- **Cmd+Shift+D** — cycle to the next display on the host (an overlay shows `Display X / Y` for ~2.5s)

The host enumerates all displays at startup and prints them. `--display N` selects the initial display; switching at runtime is done from the client with Cmd+Shift+D. When switching to a display with a different resolution, the encoder is automatically reconfigured and a keyframe is forced.

## Current limitations (MVP)

- Single viewer at a time (latest `hello` wins).
- No retransmission/FEC — on lossy Wi-Fi some frames may drop until the next keyframe (2s interval); add FEC or increase `--bitrate` headroom on a clean LAN if needed.
- Remote cursor is drawn into the video (host's physical cursor); the local cursor is hidden over the client window.
- Audio is not streamed.
- No clipboard sync, no file transfer.

## Roadmap ideas

- Adaptive bitrate based on packet loss / RTT (ping packet type already reserved in the protocol).
- HEVC/AV1 encode option (VideoToolbox supports both on Apple Silicon).
- Clipboard sync channel.
- Auto-reconnect + multi-display selection.
- LaunchDaemon / menu-bar app packaging for the host.