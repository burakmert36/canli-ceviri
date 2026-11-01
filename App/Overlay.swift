import UIKit
import AVKit
import CoreMedia
import CoreVideo
import SwiftUI

/// Altyazı kutusunu (siyah zemin, beyaz yazı) piksel tamponuna çizer.
final class OverlayRenderer {
    private let width = 1080

    struct Content {
        var original: String
        var translation: String
        var hint: String?
        var paused: Bool
        var showOriginal: Bool
        var fontSize: CGFloat
        var aspect: CGFloat
    }

    func render(_ c: Content) -> CVPixelBuffer? {
        let w = width
        let h = max(240, Int((CGFloat(w) / c.aspect).rounded()) & ~1)
        var pbOut: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pbOut) == kCVReturnSuccess,
              let pb = pbOut else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        // UIKit koordinatları (sol üst köşe başlangıç)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let pad: CGFloat = 30
        let inner = CGRect(x: pad, y: pad * 0.8, width: CGFloat(w) - pad * 2, height: CGFloat(h) - pad * 1.6)

        if let hint = c.hint, c.original.isEmpty, c.translation.isEmpty {
            let font = UIFont.systemFont(ofSize: c.fontSize * 0.9, weight: .semibold)
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            let s = NSAttributedString(string: hint, attributes: [
                .font: font, .foregroundColor: UIColor(white: 0.85, alpha: 1), .paragraphStyle: p,
            ])
            let b = s.boundingRect(with: CGSize(width: inner.width, height: .greatestFiniteMagnitude),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            s.draw(with: CGRect(x: inner.minX, y: inner.midY - b.height / 2, width: inner.width, height: b.height),
                   options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        } else {
            let tFont = UIFont.systemFont(ofSize: c.fontSize, weight: .semibold)
            let oFont = UIFont.systemFont(ofSize: c.fontSize * 0.72, weight: .regular)
            var transRect = inner
            if c.showOriginal && !c.original.isEmpty {
                let oLine = lineHeight(oFont)
                let tLine = lineHeight(tFont)
                // Orijinal metne en fazla 2 satır, çeviriye en az 1 satır bırak.
                let maxOLines = max(1, min(2, Int((inner.height - tLine - 10) / oLine)))
                let oRect = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: CGFloat(maxOLines) * oLine)
                drawTail(c.original, font: oFont, color: UIColor(white: 0.62, alpha: 1), in: oRect, ctx: ctx)
                let sepY = oRect.maxY + 5
                transRect = CGRect(x: inner.minX, y: sepY + 5, width: inner.width, height: inner.maxY - sepY - 5)
            }
            drawTail(c.translation, font: tFont, color: .white, in: transRect, ctx: ctx)
        }

        if c.paused {
            let s = NSAttributedString(string: "⏸", attributes: [
                .font: UIFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: UIColor.systemYellow,
            ])
            s.draw(at: CGPoint(x: CGFloat(w) - 56, y: 8))
        }
        return pb
    }

    private func lineHeight(_ f: UIFont) -> CGFloat { (f.lineHeight * 1.06).rounded() }

    /// Metni kutuya sığdırır; taşarsa en yeni (alttaki) satırlar görünür.
    private func drawTail(_ text: String, font: UIFont, color: UIColor, in rect: CGRect, ctx: CGContext) {
        guard !text.isEmpty, rect.height > 0 else { return }
        let lh = lineHeight(font)
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lh
        p.maximumLineHeight = lh
        p.lineBreakMode = .byWordWrapping
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
        let b = s.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let textH = ceil(b.height)
        let lines = max(1, floor(rect.height / lh))
        let visibleH = lines * lh
        let y = rect.minY - max(0, textH - visibleH)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: rect.minX - 4, y: rect.minY, width: rect.width + 8, height: visibleH))
        s.draw(with: CGRect(x: rect.minX, y: y, width: rect.width, height: textH),
               options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        ctx.restoreGState()
    }
}

/// Kutuyu "Resim içinde Resim" penceresi olarak tüm uygulamaların üstünde gösterir.
final class PiPManager: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var startAttempts = 0
    private(set) var isActive = false
    private var stopRequested = false
    private var restoring = false

    var paused = false
    var onUserClosed: (() -> Void)?
    var onPauseToggled: ((Bool) -> Void)?
    var onStatus: ((String) -> Void)?
    var onActiveChanged: ((Bool) -> Void)?

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer,
                                                                playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        c.requiresLinearPlayback = true
        c.canStartPictureInPictureAutomaticallyFromInline = false
        controller = c
    }

    var autoStartWhenBackgrounded: Bool {
        get { controller?.canStartPictureInPictureAutomaticallyFromInline ?? false }
        set { controller?.canStartPictureInPictureAutomaticallyFromInline = newValue }
    }

    func enqueue(_ pb: CVPixelBuffer) {
        var fmt: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                           formatDescriptionOut: &fmt) == noErr,
              let format = fmt else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sbOut: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sbOut) == noErr,
              let sb = sbOut else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sb)
    }

    func start() {
        guard let c = controller else {
            onStatus?("Bu cihaz Resim içinde Resim desteklemiyor")
            return
        }
        stopRequested = false
        startAttempts = 0
        tryStart(c)
    }

    private func tryStart(_ c: AVPictureInPictureController) {
        if c.isPictureInPictureActive { return }
        if c.isPictureInPicturePossible {
            c.startPictureInPicture()
        } else if startAttempts < 25 {
            startAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.tryStart(c) }
        } else {
            onStatus?("Kutu açılamadı. Ayarlar > Genel > Resim içinde Resim açık mı?")
        }
    }

    func stop() {
        stopRequested = true
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
    }

    func refreshControls() { controller?.invalidatePlaybackState() }

    // MARK: AVPictureInPictureControllerDelegate

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        isActive = true
        onActiveChanged?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        isActive = false
        onActiveChanged?(false)
        // Kutudaki "uygulamaya dön" düğmesi çeviriyi durdurmaz; yalnızca ✕ ile kapatmak durdurur.
        if !stopRequested && !restoring { onUserClosed?() }
        restoring = false
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        onStatus?("Kutu açılamadı: \(error.localizedDescription)")
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        restoring = true
        completionHandler(true)
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate

    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        paused = !playing
        onPauseToggled?(paused)
        c.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        paused
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

/// Önizleme: PiP katmanını uygulama içinde gösterir (PiP'in çalışması için katmanın ekranda olması gerekir).
final class LayerHostView: UIView {
    let hosted: CALayer
    init(hosted: CALayer) {
        self.hosted = hosted
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(hosted)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.frame = bounds
        CATransaction.commit()
    }
}

struct OverlayPreview: UIViewRepresentable {
    let layer: CALayer
    func makeUIView(context: Context) -> LayerHostView { LayerHostView(hosted: layer) }
    func updateUIView(_ uiView: LayerHostView, context: Context) {
        if uiView.hosted.superlayer !== uiView.layer { uiView.layer.addSublayer(uiView.hosted) }
        uiView.setNeedsLayout()
    }
}
