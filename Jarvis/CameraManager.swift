@preconcurrency import AVFoundation
import CoreImage
import Observation
import UIKit

/// Grabs frames off the capture queue. It does two things per frame:
///   1. Enqueues the frame into a shared AVSampleBufferDisplayLayer for a smooth
///      live preview (more reliable across devices than AVCaptureVideoPreviewLayer).
///   2. Keeps the most recent frame as a compressed JPEG (throttled) so the
///      assistant can snapshot "what the phone sees right now" instantly.
final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var storedJPEG: Data?
    private var lastEncode = CFAbsoluteTimeGetCurrent()
    private var didLogFirstFrame = false

    /// Live preview target. Weak: owned by CameraManager.
    weak var displayLayer: AVSampleBufferDisplayLayer?
    /// Fired (throttled, on a background queue) so the UI can show a frame counter.
    var onFrameTick: (@Sendable () -> Void)?

    var latestJPEG: Data? {
        lock.lock(); defer { lock.unlock() }
        return storedJPEG
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // --- 1. Live preview: display every frame immediately. ---
        if let layer = displayLayer {
            setDisplayImmediately(sampleBuffer)
            let buffer = sampleBuffer
            DispatchQueue.main.async {
                // iOS 17+: the layer-level enqueue is deprecated and renders
                // unreliably. Drive the modern sampleBufferRenderer instead.
                let renderer = layer.sampleBufferRenderer
                if renderer.requiresFlushToResumeDecoding {
                    renderer.flush()
                }
                if renderer.isReadyForMoreMediaData {
                    renderer.enqueue(buffer)
                }
            }
        }

        // --- 2. Snapshot JPEG, throttled to ~3 fps to save battery. ---
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastEncode >= 0.3 else { return }
        lastEncode = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        #if DEBUG
        if !didLogFirstFrame {
            didLogFirstFrame = true
            print("[JARVIS][Camera] first video frame \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
        }
        #endif
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let maxDimension = max(source.extent.width, source.extent.height)
        let scale = min(1, 1280 / maxDimension)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        if let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) {
            let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.78)
            lock.lock(); storedJPEG = data; lock.unlock()
        }
        onFrameTick?()
    }

    /// Tell AVSampleBufferDisplayLayer to show the frame now (no timebase needed).
    private func setDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let raw = CFArrayGetValueAtIndex(attachments, 0)
        let dict = unsafeBitCast(raw, to: CFMutableDictionary.self)
        CFDictionarySetValue(dict,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}

@Observable
@MainActor
final class CameraManager {
    enum State: Equatable {
        case idle
        case configuring
        case running
        case denied
        case failed(String)
    }

    let session = AVCaptureSession()
    /// Shared preview layer, driven by FrameGrabber and shown by CameraPreview.
    let displayLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    private let grabber = FrameGrabber()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "jarvis.camera.session", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "jarvis.camera.frames", qos: .userInitiated)
    private var isConfigured = false

    private(set) var state: State = .idle
    /// Climbs while frames flow — surfaced in the on-screen diagnostic line.
    private(set) var previewFrameCount = 0

    var canCapture: Bool {
        state == .running && grabber.latestJPEG != nil
    }

    func start() {
        guard state != .configuring, state != .running else { return }
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        #if DEBUG
        print("[JARVIS][Camera] authorization=\(authorization.rawValue)")
        #endif
        switch authorization {
        case .authorized:
            beginSession()
        case .notDetermined:
            state = .configuring
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted { self.beginSession() } else { self.state = .denied }
                }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
        state = .idle
    }

    func captureJPEG() -> Data? {
        grabber.latestJPEG
    }

    private func beginSession() {
        state = .configuring
        grabber.displayLayer = displayLayer
        grabber.onFrameTick = { [weak self] in
            Task { @MainActor in self?.previewFrameCount &+= 1 }
        }

        let session = self.session
        let output = self.output
        let grabber = self.grabber
        let sampleQueue = self.sampleQueue
        let alreadyConfigured = isConfigured

        sessionQueue.async { [weak self] in
            if alreadyConfigured {
                if !session.isRunning { session.startRunning() }
                let isRunning = session.isRunning
                Task { @MainActor in self?.state = isRunning ? .running : .failed("摄像头未能启动，请关闭 App 后重试。") }
                return
            }

            // CRITICAL: do NOT let the capture session reconfigure the shared
            // audio session — that hijacks it and starves the speech recognizer,
            // leaving the mic stuck on "请开口说话…". We manage audio ourselves.
            session.automaticallyConfiguresApplicationAudioSession = false

            session.beginConfiguration()
            session.sessionPreset = .hd1280x720

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                Task { @MainActor in
                    self?.isConfigured = false
                    self?.state = .failed("无法访问后置摄像头（模拟器没有摄像头，请用真机或导入图片）。")
                }
                return
            }
            session.addInput(input)

            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(grabber, queue: sampleQueue)
            guard session.canAddOutput(output) else {
                session.removeInput(input)
                session.commitConfiguration()
                Task { @MainActor in
                    self?.isConfigured = false
                    self?.state = .failed("摄像头视频输出不可用，请重新启动 App。")
                }
                return
            }
            session.addOutput(output)
            if let connection = output.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90 // upright portrait frames
            }

            session.commitConfiguration()
            session.startRunning()
            let isRunning = session.isRunning
            Task { @MainActor in
                self?.isConfigured = isRunning
                self?.state = isRunning ? .running : .failed("摄像头未能启动，请确认相机权限后重试。")
                #if DEBUG
                print("[JARVIS][Camera] configured isRunning=\(isRunning)")
                #endif
            }
        }
    }

    var diagnostic: String {
        switch state {
        case .denied:
            "相机权限被拒绝。请在“设置 › JARVIS”中打开相机，或导入一张图片继续。"
        case .failed(let message):
            message
        default:
            "正在准备摄像头…"
        }
    }
}
