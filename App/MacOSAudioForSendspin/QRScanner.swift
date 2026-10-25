import AVFoundation
import SwiftUI
import Vision

/// The camera, live, reading QR codes: for a speaker's pairing token printed on it or its
/// leaflet. It runs only while it's shown.
struct QRScanner: NSViewRepresentable {
    /// Each QR code it reads, as text.
    let onCode: @MainActor @Sendable (String) -> Void

    /// There's a camera, and the user hasn't refused it to this app.
    static var isAvailable: Bool {
        guard AVCaptureDevice.default(for: .video) != nil else { return false }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted: return false
        default: return true
        }
    }

    func makeNSView(context: Context) -> View { View(reader: QRReader(onCode: onCode)) }
    /// The handler of the view as it is now, not as it was when the camera started.
    func updateNSView(_ nsView: View, context: Context) { nsView.reader.onCode = onCode }

    final class View: NSView {
        let reader: QRReader

        init(reader: QRReader) {
            self.reader = reader
            super.init(frame: .zero)
            wantsLayer = true
            layer = reader.previewLayer
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { reader.start() } else { reader.stop() }
        }
    }
}

/// The capture session and the reading, on a queue of their own.
final class QRReader: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let previewLayer: AVCaptureVideoPreviewLayer
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "eu.vooijs.MacOSAudioForSendspin.qr")
    /// Set on the main thread, read there.
    @MainActor var onCode: @MainActor @Sendable (String) -> Void
    // On `queue`.
    private var configured = false
    private var lastRead = Date.distantPast

    init(onCode: @escaping @MainActor @Sendable (String) -> Void) {
        self.onCode = onCode
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init()
    }

    func start() {
        // The first time, macOS asks the user (NSCameraUsageDescription).
        AVCaptureDevice.requestAccess(for: .video) { [self] granted in
            guard granted else { return }
            queue.async { [self] in
                if !configured { configure() }
                if !session.isRunning { session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        configured = true
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
        session.beginConfiguration()
        session.sessionPreset = .medium
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        // As a mirror, as FaceTime shows it: moving the leaflet left moves it left.
        DispatchQueue.main.async { [previewLayer] in
            if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // A few looks a second are plenty.
        guard Date().timeIntervalSince(lastRead) > 0.25 else { return }
        lastRead = Date()
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cmSampleBuffer: sampleBuffer, options: [:]).perform([request])
        guard let text = request.results?.compactMap(\.payloadStringValue).first else { return }
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { onCode(text) } }
    }
}
