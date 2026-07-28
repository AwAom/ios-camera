import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var stealthMode = StealthModeController()
    @StateObject private var streamStats = StreamStats()
    @State private var mjpegServer: MJPEGServer?
    @State private var streamingEnabled = false
    @State private var previewEnabled = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(session: cameraManager.session, isEnabled: previewEnabled)
                .ignoresSafeArea()
                .opacity((stealthMode.isActive || !previewEnabled) ? 0 : 1)

            // Pure black OLED overlay: on modern iPhones (OLED panels) this
            // switches the covered pixels off entirely, cutting power draw
            // and heat versus leaving the preview rendering underneath.
            Color.black
                .ignoresSafeArea()
                .opacity(stealthMode.isActive ? 1 : 0)
                .allowsHitTesting(false)

            if !stealthMode.isActive {
                overlayHUD
            }
        }
        // Explicit content shape: without this, the double-tap gesture has
        // nothing to register against while stealth mode is active, since
        // every child view has hit-testing disabled at that point (the
        // preview intentionally, the black overlay via allowsHitTesting) --
        // that left the ZStack with no defined tappable area at all, which
        // is why double-tap could turn stealth mode on but never back off.
        .contentShape(Rectangle())
        // Double-tap anywhere toggles stealth mode on/off.
        .onTapGesture(count: 2) {
            stealthMode.toggle()
        }
        .onAppear {
            // Microphone stays off until the user explicitly enables it
            // via the Mic toggle (see CameraManager.setAudioEnabled).
            cameraManager.requestPermissionsAndConfigure()
            UIApplication.shared.isIdleTimerDisabled = true
            // Trigger the Local Network permission prompt early so the
            // MJPEG server can actually accept inbound connections later.
            LocalNetworkPermission.shared.requestIfNeeded()
        }
        .onDisappear {
            cameraManager.stop()
            mjpegServer?.stop()
        }
        .statusBar(hidden: true)
    }

    private var overlayHUD: some View {
        VStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cameraManager.activeFormatDescription)
                            .font(.caption.monospaced())
                        if streamingEnabled {
                            Text("Stream: \(String(format: "%.1f", streamStats.fps)) fps · \(Int(streamStats.kbps)) kbps · \(streamStats.connectedClients) client(s)")
                                .font(.caption2.monospaced())
                                .foregroundColor(.green)
                        }
                        if let error = cameraManager.lastError {
                            Text(error)
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                    }
                    .padding(8)
                    .background(.black.opacity(0.5))
                    .cornerRadius(8)

                    Spacer()
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Menu {
                            ForEach(CameraManager.QualityPreset.allCases) { preset in
                                Button {
                                    cameraManager.setQualityPreset(preset)
                                } label: {
                                    if preset == cameraManager.selectedQualityPreset {
                                        Label(preset.label, systemImage: "checkmark")
                                    } else {
                                        Text(preset.label)
                                    }
                                }
                            }
                        } label: {
                            Label(cameraManager.selectedQualityPreset.label, systemImage: "gearshape")
                                .font(.caption)
                        }
                        .padding(8)
                        .background(.black.opacity(0.5))
                        .cornerRadius(8)

                        if cameraManager.availableCameras.count > 1 {
                            Menu {
                                ForEach(cameraManager.availableCameras, id: \.uniqueID) { device in
                                    Button {
                                        cameraManager.selectCamera(device)
                                    } label: {
                                        if device.uniqueID == cameraManager.currentCameraID {
                                            Label(device.localizedName, systemImage: "checkmark")
                                        } else {
                                            Text(device.localizedName)
                                        }
                                    }
                                }
                            } label: {
                                Label(currentCameraName, systemImage: "camera.rotate")
                                    .font(.caption)
                            }
                            .padding(8)
                            .background(.black.opacity(0.5))
                            .cornerRadius(8)
                        }

                        Toggle(isOn: Binding(
                            get: { previewEnabled },
                            set: { previewEnabled = $0 }
                        )) {
                            Label("Preview", systemImage: previewEnabled ? "eye" : "eye.slash")
                                .font(.caption)
                        }
                        .toggleStyle(.button)
                        .padding(8)
                        .background(.black.opacity(0.5))
                        .cornerRadius(8)

                        Toggle(isOn: Binding(
                            get: { cameraManager.audioEnabled },
                            set: { cameraManager.setAudioEnabled($0) }
                        )) {
                            Label("Mic", systemImage: cameraManager.audioEnabled ? "mic" : "mic.slash")
                                .font(.caption)
                        }
                        .toggleStyle(.button)
                        .padding(8)
                        .background(.black.opacity(0.5))
                        .cornerRadius(8)

                        Toggle(isOn: $streamingEnabled) {
                            Text("MJPEG :8080")
                                .font(.caption)
                        }
                        .toggleStyle(.button)
                        .onChange(of: streamingEnabled) { enabled in
                            toggleStreaming(enabled)
                        }
                        .padding(8)
                        .background(.black.opacity(0.5))
                        .cornerRadius(8)
                    }
                }
            }
            .padding()

            Spacer()

            Text("Double-tap anywhere to toggle stealth (black-screen) mode")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
                .padding(.bottom, 24)
        }
    }

    private var currentCameraName: String {
        cameraManager.availableCameras.first(where: { $0.uniqueID == cameraManager.currentCameraID })?.localizedName ?? "Camera"
    }

    private func toggleStreaming(_ enabled: Bool) {
        if enabled {
            let server = MJPEGServer(port: 8080, stats: streamStats)
            cameraManager.frameConsumer = server
            server.start()
            mjpegServer = server
        } else {
            mjpegServer?.stop()
            mjpegServer = nil
            cameraManager.frameConsumer = nil
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
