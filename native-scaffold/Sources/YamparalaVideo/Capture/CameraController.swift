import AVFoundation
import Combine
import SwiftUI

@MainActor
final class CameraController: ObservableObject {
    @Published var deviceName = "No camera"
    @Published var availableDevices: [AVCaptureDevice] = []
    @Published var status: Status = .idle
    @Published var isHidden = false { didSet { LiveState.shared.setCamera(mirrored: isMirrored, hidden: isHidden) } }
    @Published var isMirrored = true { didSet { LiveState.shared.setCamera(mirrored: isMirrored, hidden: isHidden) } }

    enum Status: Equatable {
        case idle, denied, running, failed(String)
    }

    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) private var videoInput: AVCaptureDeviceInput?
    nonisolated(unsafe) private var audioInput: AVCaptureDeviceInput?
    nonisolated(unsafe) let videoOutput = AVCaptureVideoDataOutput()
    nonisolated(unsafe) let audioOutput = AVCaptureAudioDataOutput()
    nonisolated(unsafe) let tap = CaptureTap()
    @Published var micName = "No microphone"
    private let sessionQueue = DispatchQueue(label: "xyz.penfight.stream.camera")

    func start() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            Diagnostics.shared.note("videoAccess=\(granted)")
            guard granted else { status = .denied; return }
            refreshDevices()
            configureOutputs()
            guard let device = availableDevices.first else {
                status = .failed("no camera found"); return
            }
            select(device)

            // Deliberately not awaited above: an unanswered microphone prompt
            // would otherwise stall camera setup behind it.
            Task {
                let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
                Diagnostics.shared.note("micAccess=\(micGranted)")
                guard micGranted else { return }
                attachMicrophone()
            }
        }
    }

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        availableDevices = discovery.devices
    }

    func select(_ device: AVCaptureDevice) {
        deviceName = device.localizedName
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if let existing = self.videoInput { self.session.removeInput(existing) }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.videoInput = input
                }
                self.session.commitConfiguration()
                if !self.session.isRunning { self.session.startRunning() }
                Task { @MainActor in self.status = .running }
            } catch {
                self.session.commitConfiguration()
                Task { @MainActor in self.status = .failed(error.localizedDescription) }
            }
        }
    }

    /// Frame and microphone taps the recorder reads from. Attached once, kept
    /// running for the life of the session so recording can start instantly.
    private func configureOutputs() {
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(tap, queue: tap.queue)

        audioOutput.setSampleBufferDelegate(tap, queue: tap.queue)

        sessionQueue.async { [self] in
            session.beginConfiguration()
            let videoOK = session.canAddOutput(videoOutput)
            if videoOK { session.addOutput(videoOutput) }
            let audioOK = session.canAddOutput(audioOutput)
            if audioOK { session.addOutput(audioOutput) }
            session.commitConfiguration()
            Diagnostics.shared.note("outputs videoOK=\(videoOK) audioOK=\(audioOK)")
        }
    }

    private func attachMicrophone() {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            Diagnostics.shared.note("no audio device")
            return
        }
        micName = device.localizedName
        sessionQueue.async { [self] in
            session.beginConfiguration()
            if let existing = audioInput { session.removeInput(existing) }
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                audioInput = input
                Diagnostics.shared.note("mic attached: \(device.localizedName)")
            } else {
                Diagnostics.shared.note("mic input rejected")
            }
            session.commitConfiguration()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }
}


/// Receives camera frames and microphone packets on one queue and forwards
/// them to whoever is listening (the recorder, when a take is running).
final class CaptureTap: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                        AVCaptureAudioDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "xyz.penfight.stream.tap")

    private let lock = NSLock()
    private var _onCameraFrame: ((CVPixelBuffer) -> Void)?
    private var _onMicBuffer: ((CMSampleBuffer) -> Void)?

    var onCameraFrame: ((CVPixelBuffer) -> Void)? {
        get { lock.withLock { _onCameraFrame } }
        set { lock.withLock { _onCameraFrame = newValue } }
    }

    var onMicBuffer: ((CMSampleBuffer) -> Void)? {
        get { lock.withLock { _onMicBuffer } }
        set { lock.withLock { _onMicBuffer = newValue } }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            onCameraFrame?(pixelBuffer)
        } else {
            onMicBuffer?(sampleBuffer)
        }
    }
}

/// Live camera preview. This is what *you* see; the recorder composites the
/// camera from its own frame callbacks rather than from this layer.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.setMirrored(mirrored)
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // A layer-hosting view needs its layer assigned *before* wantsLayer,
            // otherwise AppKit replaces it and the preview sublayer is dropped.
            let host = CALayer()
            host.backgroundColor = NSColor.black.cgColor
            layer = host
            wantsLayer = true

            previewLayer.videoGravity = .resizeAspectFill
            host.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func setMirrored(_ mirrored: Bool) {
            guard let connection = previewLayer.connection,
                  connection.isVideoMirroringSupported else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}
