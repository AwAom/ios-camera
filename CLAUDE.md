# USBCam

A SwiftUI iOS app that turns an iPhone into a high-performance, battery-conscious
USB/network camera. Built and CI'd entirely without a Mac: no `.xcodeproj` is
committed, GitHub Actions generates one with XcodeGen and produces an
**unsigned** `.ipa` that gets ad-hoc signed on install by Sideloadly (free
Apple ID, no paid developer account).

If you're an agent picking this up cold: read this file, then
[README.md](README.md) for the CI/sideloading workflow, before touching code.

## What it does

- Locks the active camera to the highest usable format: 4K@60 → 4K@30 →
  1080p@60 → 1080p@30 → device default, or a user-picked exact preset.
- Lets the user pick a specific quality preset (`CameraManager.QualityPreset`)
  when auto's pick is too heavy for their use case (e.g. streaming lag).
- Enumerates and switches between every camera the device exposes (wide,
  ultra-wide, telephoto, front, virtual dual/triple) live, without tearing
  down the session.
- **Stealth mode**: double-tap anywhere to black out the screen, drop
  brightness to 0, and disable the idle timer — an OLED battery/heat saver
  that fakes a "locked/off" look while the camera keeps running in the
  foreground (see "Why not real background capture" below).
- **MJPEG HTTP server** (optional, off by default): serves the feed at
  `http://<device-ip>:8080/stream` for OBS etc. to consume over local
  Wi-Fi/USB-tethering. Frames are downscaled to a max 1280px width before
  JPEG encoding regardless of capture resolution — the per-frame encode is
  the actual streaming bottleneck, not the network.
- Mic capture is **off by default** (saves CPU/bandwidth); toggle live.
- Preview rendering can be disabled independently of stealth mode (detaches
  the `AVCaptureVideoPreviewLayer`'s session entirely, not just hides it).
- Live stream fps/kbps/client-count shown in the HUD while MJPEG is active.

## Why not real background/lock-screen capture

Explicitly ruled out, not just unimplemented: iOS suspends camera hardware
for any third-party app the instant it backgrounds (phone locks = app
backgrounds). There's no public entitlement available to a free-signed/
sideloaded app that lifts this for the locked-screen case — the narrow
`multitasking-camera-access` entitlement (iOS 16+) only covers specific
*foreground* multitasking (Slide Over etc.), not lock screen. Stealth mode
(above) is the practical ceiling on stock iOS: keep the app foregrounded
with the idle timer disabled and fake the "off" look instead of actually
locking.

## Project layout

```
project.yml                      XcodeGen spec — generates USBCam.xcodeproj in CI
Info.plist                       Camera/mic/local-network usage strings + app metadata
Sources/USBCam/
  USBCamApp.swift                 App entry point
  ContentView.swift               Main UI: preview, HUD, stealth gesture, all toggles
  CameraManager.swift              AVCaptureSession, format locking, camera/quality switching, mic toggle
  CameraPreviewView.swift          UIViewRepresentable AVCaptureVideoPreviewLayer wrapper
  StealthModeController.swift      Idle timer + brightness + black overlay state machine
  MJPEGServer.swift                Local HTTP MJPEG server (Network.framework), frame downscale, stats
  StreamStats.swift                ObservableObject the HUD binds to for live fps/kbps
  LocalNetworkPermission.swift     Forces iOS's Local Network permission prompt (see gotchas)
.github/workflows/build.yml        CI: xcodegen -> xcodebuild (unsigned) -> verify Info.plist -> .ipa artifact
ui-mockup.html                     Static HTML/CSS/JS replica of the live SwiftUI HUD for fast UI iteration
                                    without a rebuild+resideload cycle. Keep it in sync with ContentView.swift
                                    whenever the HUD layout changes.
```

## Hard-won gotchas (don't re-break these)

These cost real debugging cycles across a live device — each is load-bearing:

1. **XcodeGen's `info: path:` shorthand doesn't reliably work.** It silently
   let Xcode's modern build system synthesize its own boilerplate
   `Info.plist`, dropping `NSCameraUsageDescription`/
   `NSMicrophoneUsageDescription` entirely → instant TCC crash on launch,
   with no compile-time signal. Fix in use: set `INFOPLIST_FILE` and
   `GENERATE_INFOPLIST_FILE: NO` as **plain build settings** in
   `project.yml`, not via the `info:` key. The CI workflow also has a
   `PlistBuddy`-based verification step that fails the build if those keys
   go missing again — don't remove it.
2. **`NWListener`-based local servers never trigger iOS's Local Network
   permission prompt on their own.** Without it, the app doesn't even
   appear under Settings → Privacy & Security → Local Network, and all
   inbound connections just silently time out. `LocalNetworkPermission.swift`
   forces the prompt via a throwaway `NetServiceBrowser`/`NWBrowser` probe
   matching the `_usbcam._tcp` type declared in `Info.plist`'s
   `NSBonjourServices` — call it early (currently in `ContentView.onAppear`).
3. **Disabling a child view visually (`opacity(0)`) does not disable its
   hit-testing.** During stealth mode, every child in the root `ZStack` had
   hit-testing off (preview intentionally via `isUserInteractionEnabled`,
   black overlay via `allowsHitTesting(false)`), which left the `ZStack`
   itself with no defined tappable shape — the double-tap-to-exit gesture
   had nothing to register against. Fixed with an explicit
   `.contentShape(Rectangle())` on the gesture's container. If you add more
   overlay layers, keep this in mind.
4. **CI artifacts must be verified, not assumed correct from a green
   checkmark.** A successful `xcodebuild` says nothing about *runtime*
   correctness (see gotcha #1) — it built, not that it works. When
   debugging a device-only issue, prefer adding a build-time assertion
   (like the PlistBuddy check) over just re-shipping and hoping.
5. **Sideloadly/browser downloads can silently reuse a stale file.** When
   verifying a fix, check the artifact's `sha256` digest from the specific
   GitHub Actions run against the file actually being installed — don't
   assume "I downloaded it again" means "I got the new one."

## CI / release flow

Every push to `main` builds automatically
(`.github/workflows/build.yml`): XcodeGen generates the project, `xcodebuild`
builds fully unsigned (`CODE_SIGNING_ALLOWED=NO`, no team), the `.app` is
packaged into a standard `Payload/` IPA layout, and uploaded as the
`USBCam-unsigned-ipa` artifact. See [README.md](README.md) for the full
Sideloadly install walkthrough. Free Apple ID signatures expire after 7
days — re-signing needs re-running Sideloadly on the same `.ipa`, not a
rebuild.

## Conventions

- No paid Apple Developer account and no local Mac/Xcode are available —
  every change has to go through the CI build-and-sideload loop to test on
  device. Use `ui-mockup.html` to iterate on HUD/layout changes quickly
  before spending a CI+sideload cycle on them.
- Deployment target is iOS 15.0; don't reach for APIs newer than that
  without checking availability.
- Keep `ui-mockup.html` visually in sync with `ContentView.swift`'s actual
  SwiftUI output (same chip styling, spacing, colors, icons, copy) — it's
  meant to be a truthful preview, not a separate design.
