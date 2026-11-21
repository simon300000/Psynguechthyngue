import AVFoundation
import PsySync
import SwiftUI

struct AddDeviceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var idText = ""
    @State private var name = ""
    @State private var scanning = false
    @State private var busy = false

    private var parsed: DeviceID? { DeviceIDParser.extract(from: idText) }
    /// QR scanning needs a camera; Mac (Designed for iPad) uses paste instead.
    private var canScan: Bool {
        !model.isOnMac && AVCaptureDevice.default(for: .video) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Device ID", text: $idText, axis: .vertical)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)
                        .accessibilityIdentifier("adddevice.id")
                    HStack {
                        PasteButton(payloadType: String.self) { strings in
                            if let s = strings.first { idText = s }
                        }
                        .accessibilityIdentifier("adddevice.paste")
                        if canScan {
                            Spacer()
                            Button { scanning = true } label: { Label("Scan QR Code", systemImage: "qrcode.viewfinder") }
                                .accessibilityIdentifier("adddevice.scan")
                        }
                    }
                    validation
                } header: {
                    Text("Device ID")
                } footer: {
                    Text(model.isOnMac
                         ? "Copy the ID from the other device’s Syncthing screen and paste it here."
                         : "Scan the QR code shown on the other device, or paste its ID.")
                }
                Section("Name") {
                    TextField("Optional", text: $name)
                        .accessibilityIdentifier("adddevice.name")
                }
            }
            .navigationTitle("Add Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(parsed == nil || busy)
                        .accessibilityIdentifier("adddevice.add")
                }
            }
            .fullScreenCover(isPresented: $scanning) {
                QRScannerScreen { text in
                    if let id = DeviceIDParser.extract(from: text) {
                        idText = id.rawValue
                        scanning = false
                        return true
                    }
                    return false
                }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private var validation: some View {
        if idText.isEmpty {
            EmptyView()
        } else if let id = parsed {
            Label("Valid device ID (\(id.short)…)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.footnote)
                .accessibilityIdentifier("adddevice.valid")
        } else {
            Label("This is not a valid device ID.", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.footnote)
                .accessibilityIdentifier("adddevice.invalid")
        }
    }

    private func add() {
        guard let id = parsed else { return }
        busy = true
        Task {
            let ok = await model.addDevice(id: id, name: name)
            busy = false
            if ok { dismiss() }
        }
    }
}

/// Live camera preview that recognises Syncthing device-ID QR codes
/// automatically — no capture button.
struct QRScannerScreen: View {
    /// Return true when the payload was accepted (stops scanning).
    let onPayload: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var denied = false

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerRepresentable(onPayload: onPayload, onDenied: { denied = true })
                    .ignoresSafeArea()
                if denied {
                    ContentUnavailableView {
                        Label("Camera access is off", systemImage: "camera.fill")
                    } description: {
                        Text("Allow camera access in Settings to scan QR codes, or paste the device ID instead.")
                    }
                    .background(.regularMaterial)
                } else {
                    VStack {
                        Spacer()
                        Text("Point the camera at the QR code on the other device")
                            .padding(10).background(.regularMaterial, in: Capsule()).padding(.bottom, 40)
                    }
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onPayload: (String) -> Bool
    let onDenied: () -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.onPayload = onPayload
        vc.onDenied = onDenied
        return vc
    }
    func updateUIViewController(_ vc: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
        var onPayload: ((String) -> Bool)?
        var onDenied: (() -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var finished = false

        override func viewDidLoad() {
            super.viewDidLoad()
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: configure()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { ok in
                    DispatchQueue.main.async { ok ? self.configure() : self.onDenied?() }
                }
            default: onDenied?()
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { onDenied?(); return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            preview = layer
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !finished,
                  let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            if onPayload?(text) == true {
                finished = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }
}
