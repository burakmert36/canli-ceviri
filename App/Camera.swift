import Foundation
import AVFoundation
import UIKit
import SwiftUI
import ImageIO

// MARK: - Kamera

/// Arka kamerayı açar, saniyede ~2,5 kare gri tonlamalı görüntü üretir (altyazı okumak için).
final class CameraCapture: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    /// Görüntü dik mi (telefon/tablet dik tutuluyor)?
    @Published private(set) var isPortraitImage = true
    @Published private(set) var unavailable = false
    @Published private(set) var maxZoom: CGFloat = 5

    /// Kamera kuyruğunda çağrılır.
    var onFrame: ((ScreenFrame) -> Void)?

    private let queue = DispatchQueue(label: "canliceviri.camera", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private(set) var device: AVCaptureDevice?
    private var configured = false
    private let lock = NSLock()
    private var captureAngle: CGFloat = 90
    private var lastFrameAt = Date.distantPast

    /// Oturumu hazırlar (ana iş parçacığında, bir kez).
    func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .high
        }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            session.commitConfiguration()
            unavailable = true
            return
        }
        session.addInput(input)
        device = dev
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        if (try? dev.lockForConfiguration()) != nil {
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            dev.unlockForConfiguration()
        }
        maxZoom = max(1, min(8, dev.activeFormat.videoMaxZoomFactor))
        setFrameRate(15)
    }

    func start() {
        configureIfNeeded()
        guard !unavailable else { return }
        queue.async { if !self.session.isRunning { self.session.startRunning() } }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func setZoom(_ factor: CGFloat) {
        guard let d = device else { return }
        let z = max(1, min(factor, maxZoom))
        queue.async {
            guard (try? d.lockForConfiguration()) != nil else { return }
            d.videoZoomFactor = z
            d.unlockForConfiguration()
        }
    }

    /// Kamera kare hızını sınırlar (daha az ısınma ve pil). Altyazı okumak için 10–15 kare/sn yeterli.
    func setFrameRate(_ fps: Int) {
        guard let d = device else { return }
        queue.async {
            let supported = d.activeFormat.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate
            }
            guard supported, (try? d.lockForConfiguration()) != nil else { return }
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            d.activeVideoMinFrameDuration = duration
            d.activeVideoMaxFrameDuration = duration
            d.unlockForConfiguration()
        }
    }

    /// Önizleme katmanından gelen döndürme açısı (0/90/180/270).
    func setCaptureAngle(_ angle: CGFloat) {
        lock.lock(); captureAngle = angle; lock.unlock()
        let portrait = Int(angle.rounded()) % 180 != 0
        if isPortraitImage != portrait { isPortraitImage = portrait }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let handler = onFrame else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFrameAt) >= 0.4 else { return }
        lastFrameAt = now
        lock.lock(); let angle = captureAngle; lock.unlock()
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = FrameGrabber.gray(pb, orientation: Self.orientation(for: angle)) else { return }
        handler(frame)
    }

    static func orientation(for angle: CGFloat) -> CGImagePropertyOrientation {
        switch ((Int(angle.rounded()) % 360) + 360) % 360 {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }
}

/// Kamera görüntüsünün parlaklık kanalını küçültüp gri kareye çevirir.
enum FrameGrabber {
    static func gray(_ pb: CVPixelBuffer, orientation: CGImagePropertyOrientation, maxSide: Int = 1300) -> ScreenFrame? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferIsPlanar(pb), let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard w > 8, h > 8 else { return nil }
        let f = max(1, max(w, h) / maxSide)
        let ow = w / f, oh = h / f
        var out = Data(count: ow * oh)
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let o = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let src = base.assumingMemoryBound(to: UInt8.self)
            if f == 1 {
                for y in 0..<oh { memcpy(o + y * ow, src + y * bpr, ow) }
                return
            }
            let area = f * f
            for y in 0..<oh {
                for x in 0..<ow {
                    var sum = 0
                    for dy in 0..<f {
                        let row = src + (y * f + dy) * bpr + x * f
                        for dx in 0..<f { sum += Int(row[dx]) }
                    }
                    o[y * ow + x] = UInt8(sum / area)
                }
            }
        }
        return ScreenFrame(width: ow, height: oh, orientation: orientation, pixels: out, time: Date())
    }
}

/// Kamera önizlemesi; cihaz döndükçe görüntüyü dik tutar ve okuma yönünü kameraya bildirir.
final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer {
        // layerClass sayesinde her zaman bu türdedir.
        layer as! AVCaptureVideoPreviewLayer
    }
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observations: [NSKeyValueObservation] = []
    private weak var capture: CameraCapture?

    func attach(_ capture: CameraCapture) {
        self.capture = capture
        backgroundColor = .black
        if previewLayer.session !== capture.session { previewLayer.session = capture.session }
        previewLayer.videoGravity = .resizeAspect
        guard coordinator == nil, let dev = capture.device else { return }
        let c = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: previewLayer)
        coordinator = c
        observations = [
            c.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyRotation() }
            },
            c.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyRotation() }
            },
        ]
        applyRotation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyRotation()
    }

    private func applyRotation() {
        guard let c = coordinator else { return }
        let previewAngle = c.videoRotationAngleForHorizonLevelPreview
        if let conn = previewLayer.connection, conn.isVideoRotationAngleSupported(previewAngle) {
            conn.videoRotationAngle = previewAngle
        }
        capture?.setCaptureAngle(c.videoRotationAngleForHorizonLevelCapture)
    }
}

struct CameraPreview: UIViewRepresentable {
    let capture: CameraCapture
    func makeUIView(context: Context) -> CameraPreviewView {
        let v = CameraPreviewView()
        capture.configureIfNeeded()
        v.attach(capture)
        return v
    }
    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        uiView.attach(capture)
    }
}

// MARK: - Mikrofon

/// Mikrofonu dinler ve 16 kHz mono Int16 örnekler üretir.
final class MicCapture {
    private let engine = AVAudioEngine()
    private var running = false
    /// Ses iş parçacığında çağrılır.
    var onSamples: (([Int16]) -> Void)?

    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw APIError.unsupported("Mikrofon biçimi desteklenmiyor")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            let ratio = 16000.0 / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            let supplied = OnceFlag()
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied.isSet {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied.isSet = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            self?.onSamples?(samples)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}

/// Dönüştürücüye tamponu yalnızca bir kez vermek için küçük bayrak.
private final class OnceFlag {
    var isSet = false
}

// MARK: - İzinler

enum Permissions {
    static func request(camera: Bool, microphone: Bool, speech: Bool,
                        done: @escaping (_ ok: Bool, _ message: String) -> Void) {
        let settingsHint = "Ayarlar > Uygulamalar > Canlı Çeviri"
        func speechStep() {
            guard speech else { done(true, ""); return }
            AppleRecognizer.requestAuthorization { ok in
                done(ok, ok ? "" : "Konuşma tanıma izni gerekli: \(settingsHint)")
            }
        }
        func micStep() {
            guard microphone else { speechStep(); return }
            AVAudioApplication.requestRecordPermission { ok in
                DispatchQueue.main.async {
                    if ok { speechStep() } else { done(false, "Mikrofon izni gerekli: \(settingsHint)") }
                }
            }
        }
        guard camera else { micStep(); return }
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                if ok { micStep() } else { done(false, "Kamera izni gerekli: \(settingsHint)") }
            }
        }
    }

    static var cameraDenied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .video)
        return s == .denied || s == .restricted
    }
}
