import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var stealthMode = StealthModeController()
    @State private var mjpegServer: MJPEGServer?
    @State private var streamingEnabled = false

    var body: some View {
        ZStack {
            CameraPreviewView(session: cameraManager.session)
                .ignoresSafeArea()
                .opacity(stealthMode.isActive ? 0 : 1)

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
        // Double-tap anywhere toggles stealth mode on/off.
        .onTapGesture(count: 2) {
            stealthMode.toggle()
        }
        .onAppear {
            cameraManager.audioEnabled = true
            cameraManager.requestPermissionsAndConfigure()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            cameraManager.stop()
            mjpegServer?.stop()
        }
        .statusBar(hidden: true)
    }

    private var overlayHUD: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cameraManager.activeFormatDescription)
                        .font(.caption.monospaced())
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
            let server = MJPEGServer(port: 8080)
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
