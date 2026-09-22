# macvnc — minimal native macOS VNC (RFB) server

A single-file Swift VNC server that shares the **real** macOS console display
over the RFB protocol — built for headless-ish Mac runners (CI VMs, remote
build machines) where Apple's own Screen Sharing can't serve frames because
`screensharingd` lacks a Screen Recording (TCC) grant.

Because `rfbvnc` runs as a regular process, its capture/input calls are
attributed to the spawning "responsible" process's TCC grants — e.g. the agent
that launched it — so it works in places where ARDAgent-based sharing shows a
black screen.

## What it does

- RFB 3.8 (`RFB 003.008`), security type **2** (classic VNC password auth,
  DES challenge–response via CommonCrypto).
- Screen capture via **ScreenCaptureKit** (`SCStream`), ~15 fps, BGRA frames.
- Input injection via **CGEvent** (mouse move/click, scroll, keys incl.
  modifiers and arbitrary Unicode).
- Dirty-tile diffing (64 px tiles) — only changed regions are sent
  (raw encoding only).
- Client clipboard (`ClientCutText` → macOS pasteboard).
- Binds to **127.0.0.1** only by design.

Tested on macOS 26 (arm64) with noVNC → Cloudflare quick tunnel.

## Build

Either:

```bash
swiftc -O -o rfbvnc Sources/rfbvnc/rfbvnc.swift
```

or:

```bash
swift build -c release
# binary at .build/release/rfbvnc
```

Requires Xcode/Swift toolchain and the macOS SDK. No external dependencies —
Foundation, CoreGraphics, AppKit, CommonCrypto, ScreenCaptureKit only.

## Run

```bash
./rfbvnc <port> <password>
# e.g.
./rfbvnc 5901 'S0meTempPass'
```

Logs per-connection debug lines to stderr.

## Security model — read this before exposing it

- **VNC auth truncates passwords to 8 bytes.** RFB DES auth uses only the
  first 8 bytes of the password (each bit-reversed). `ExAmPl3-NotReal` is
  effectively `ExAmPl3-`. Treat the effective secret as 8 bytes → always use a
  strong random password and never reuse a real credential.
- **DES is not real encryption.** VNC auth is a challenge–response over a fixed
  DES key — fine behind other layers, insufficient as the only defense on an
  untrusted network.
- **Binds to localhost only.** The listener is `127.0.0.1` hardcoded; it is
  never reachable off-host directly. Expose it only through a controlled
  bridge (e.g. websockify/noVNC proxy, SSH forward).
- **Recommended outer layers:** serve noVNC over a random unguessable URL path
  ("token gate") and/or a TLS tunnel (e.g. `cloudflared tunnel --url
  http://127.0.0.1:<httpPort>`). The VNC port itself stays on loopback.
- **Permissions required:** Screen Recording + Accessibility/PostEvent for the
  process's responsible identity. If your launching agent already holds these
  grants, frames work immediately; on a normal Mac, Terminal/itself must be
  granted Screen Recording in System Settings → Privacy & Security.

## Protocol scope (deliberately minimal)

- Encodings supported: **raw (0)** only; incremental diffs via tile
  comparison. Clients requesting tight/zrle still get raw rects.
- Pixel format: 32 bpp, depth 24, true colour, little-endian, shifts 16/8/0
  (standard BGRA — what every browser client negotiates).
- One display (`CGMainDisplayID`), cursor rendered into frames
  (`showsCursor`).
- No RFB extensions (no resize, no QEMU/clipboard-negotiate, no audio).

## noVNC / websockify quick start

```bash
# any WS→TCP bridge works; e.g. python or node websockify:
websockify --web /path/to/noVNC 127.0.0.1:8935 127.0.0.1:5901 &
cloudflared tunnel --url http://127.0.0.1:8935
# open https://<tunnel>/vnc.html?autoconnect=true&password=<pw>&path=websockify
```

## License

MIT — see LICENSE.
