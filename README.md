# Screen Mirror — iOS sender

The iPhone counterpart to `sender-phone` (Android). Mirrors the screen + system audio to
the **same** `receiver-tv` Android TV app, over the **same** WebSocket signaling protocol
and WebRTC video stream — so the TV app needs **no changes** to accept an iPhone sender.

## Why this is structured the way it is

iOS screen sharing works through ReplayKit's "Broadcast Upload Extension" — a separate
process the system launches when the user starts a broadcast, limited to ~50MB of memory.
That's too tight to run a full WebRTC stack. So:

- **`Extension/`** (the Broadcast Upload Extension): does the *least* possible — grabs
  each video/audio sample ReplayKit hands it and immediately forwards the raw bytes to
  the main app over a local Unix-domain socket living in a shared App Group container.
  No WebRTC, no encoding, nothing memory-heavy here.
- **`App/`** (the normal app, not memory-constrained): receives those raw frames
  (`FrameReceiver.swift`), rebuilds them into pixel buffers, and feeds them into a real
  WebRTC `RTCPeerConnection` (`WebRTCSender.swift`) which does the actual hardware H.264
  encoding and sends it to the TV — functionally the same pipeline as the Android sender.
- **`Shared/`**: code used by both — the signaling-protocol client (matches
  `WebRtcSenderClient.kt` / `SignalingServer.kt` exactly), Bonjour discovery (matches
  `NsdDiscovery.kt` / `NsdAdvertiser.kt` — Bonjour and Android NSD are the same mDNS
  protocol), and the local frame-forwarding wire format.

## Building without owning a Mac

`project.yml` is an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec — a plain-text
description of the Xcode project, which avoids hand-editing Xcode's binary/XML project
file. `.github/workflows/ios-build.yml` runs on GitHub's own free macOS runners: it
installs XcodeGen, generates the real `.xcodeproj` from `project.yml`, and builds. This
means **no local or rented Mac is needed to build and test-compile this project** — only
to eventually run it on a real iPhone / submit to TestFlight, which does need:

1. An Apple Developer Program membership ($99/year, apple.com — only the account owner
   can pay for this).
2. The Team ID from that account, filled into `project.yml`'s `DEVELOPMENT_TEAM`.
3. A later addition to the CI workflow: `xcodebuild archive` + `xcodebuild -exportArchive`
   with proper signing (typically via `fastlane match` or an App Store Connect API key,
   both of which run unattended in CI — still no interactive Mac GUI required), then
   upload to TestFlight so the Apple ID holder can install it on a real iPhone.

## Current status / what's NOT done yet

- Not yet tested against a real compiler — written without access to Xcode. Expect some
  build-error iteration once CI actually compiles it for the first time (API names for
  `NWListener` unix-socket binding in particular are flagged as uncertain in
  `FrameReceiver.swift` and may need adjusting once real compiler errors are visible).
- No TestFlight/signing wiring yet (needs the Apple Developer account first).
- Video path copies raw BGRA frames across the process boundary uncompressed — fine for
  getting a first working version, but worth revisiting (e.g. downscaling, or IOSurface
  sharing instead of a byte copy) if CPU/battery usage turns out too high on-device.
- `App/Info.plist` memory-pressure handling for the extension (reducing frame rate/
  resolution under pressure) isn't implemented yet — ReplayKit will kill the extension if
  it exceeds the memory limit, which would show up as broadcasting silently stopping.
