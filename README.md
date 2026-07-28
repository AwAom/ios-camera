# USBCam — 4K60 USB/Stealth Camera (unsigned CI build, no Mac required)

A SwiftUI iOS app that:

- Locks the active camera to **4K (3840x2160) @ 60fps**, falling back to
  4K@30, then 1080p@60, then 1080p@30, then the device default
  ([`CameraManager.swift`](Sources/USBCam/CameraManager.swift)).
- **Enumerates every lens the device has** (ultra-wide, wide, telephoto,
  front, and virtual dual/triple cameras) via `AVCaptureDevice.DiscoverySession`
  and lets you switch between them live from a menu in the HUD — the format
  lock (4K60 -> fallbacks) is re-applied automatically to whichever camera
  you pick.
- Provides an **OLED stealth/black-screen mode**: disables the idle timer, drops
  screen brightness to 0, and shows a pure black `#000000` overlay so OLED pixels
  switch off. Double-tap anywhere to toggle it
  ([`StealthModeController.swift`](Sources/USBCam/StealthModeController.swift),
  [`ContentView.swift`](Sources/USBCam/ContentView.swift)).
- Exposes the live feed over the standard AVFoundation pipeline (works over
  USB tethering / Wi-Fi like any capture app), plus an optional built-in
  **MJPEG HTTP server** on port `8080` so OBS on a PC can pull the stream
  directly (`http://<iphone-ip>:8080/stream`) without any third-party
  dependency ([`MJPEGServer.swift`](Sources/USBCam/MJPEGServer.swift)).

The project has **no `.xcodeproj` committed**. Instead it ships a
[`project.yml`](project.yml) ([XcodeGen](https://github.com/yonaskolb/XcodeGen)
spec); the GitHub Actions workflow generates the Xcode project on the
macOS runner and builds it fully **unsigned**, which is exactly what
Sideloadly/AltStore need — they perform ad-hoc signing themselves using
your free Apple ID at install time.

## Project layout

```
project.yml                     XcodeGen spec (target, deployment target 15.0, signing disabled)
Info.plist                      Camera/mic/local-network usage strings + app metadata
Sources/USBCam/
  USBCamApp.swift                App entry point
  ContentView.swift              Main UI: preview, stealth overlay, tap gesture, HUD
  CameraManager.swift            AVCaptureSession setup, 4K60 format lock + fallbacks
  CameraPreviewView.swift        UIViewRepresentable AVCaptureVideoPreviewLayer wrapper
  StealthModeController.swift    Idle timer + brightness + black overlay state
  MJPEGServer.swift               Optional local HTTP MJPEG server for OBS
.github/workflows/build.yml      CI: xcodegen -> xcodebuild (unsigned) -> .ipa artifact
```

## How the CI build produces an unsigned `.ipa`

1. `xcodegen generate` turns `project.yml` into `USBCam.xcodeproj` on the runner.
2. `xcodebuild ... -sdk iphoneos -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`
   builds a real device (`arm64`) `.app` bundle with no signature at all —
   this does **not** require any Apple Developer account, certificate, or
   provisioning profile.
3. The workflow copies `USBCam.app` into `Payload/`, zips it as `USBCam.ipa`
   (standard IPA layout), and uploads it as a workflow artifact.

## Step-by-step: get the `.ipa` from Windows, no Mac needed

1. **Push this repo to GitHub.**
   ```bash
   git init
   git add .
   git commit -m "Initial USBCam project"
   git branch -M main
   git remote add origin https://github.com/<your-username>/<your-repo>.git
   git push -u origin main
   ```
2. **Trigger the build.** Pushing to `main` triggers it automatically. You can
   also run it manually: GitHub repo -> **Actions** tab -> **Build Unsigned IPA**
   workflow -> **Run workflow**.
3. **Wait for the run to finish** (a few minutes — Xcode/XcodeGen setup + build).
4. **Download the artifact.** Open the finished run in the **Actions** tab,
   scroll to **Artifacts**, download `USBCam-unsigned-ipa.zip`. Unzip it on
   Windows to get `USBCam.ipa`.
5. **Install with Sideloadly** (Windows):
   - Install [Sideloadly](https://sideloadly.io/) and iTunes/Apple Mobile
     Device Support (Sideloadly's installer offers this) so Windows can talk
     to your iPhone over USB.
   - Plug in your iPhone, trust the computer if prompted.
   - Open Sideloadly, drag `USBCam.ipa` into it.
   - Enter your (free) Apple ID when prompted — Sideloadly will sign the
     unsigned IPA on the fly with a personal/free provisioning profile and
     install it.
   - On the iPhone: **Settings -> General -> VPN & Device Management** ->
     trust your Apple ID developer profile the first time you install any
     app this way.
   - Free Apple ID signatures expire after **7 days**; re-run Sideloadly
     (no rebuild needed, same `.ipa`) to re-sign/reinstall, or use a paid
     Apple Developer account for a 1-year signature if you have one.

## Notes / limitations

- Free Apple ID sideloaded apps are limited to a small number of active
  app IDs at once and expire weekly — this is an Apple platform limitation,
  not something fixable in the app or CI.
- 4K@60 requires a device whose wide-angle camera format actually supports
  it (recent iPhones); `CameraManager` automatically negotiates the best
  available format and reports it in the on-screen HUD
  (`cameraManager.activeFormatDescription`).
- The MJPEG server is a convenience preview/bonus feature (capped at 15fps,
  JPEG-compressed) — not a substitute for the full-quality native capture
  pipeline.
