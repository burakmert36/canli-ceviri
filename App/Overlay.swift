import UIKit
import AVKit
import CoreMedia
import CoreVideo
import SwiftUI

/// Altyazı kutusunu (siyah zemin) piksel tamponuna çizer.
/// Kutunun genişliği sabittir; yüksekliği seçilen satır sayısına göre hesaplanır.
/// Böylece kutu "sadece boyuna" (satır sayısı) ve "sadece enine" (yazı boyutu = satıra sığan kelime) ayarlanabilir.
final class OverlayRenderer {
    static let width: CGFloat = 1080
    static let padH: CGFloat = 30
    static let padV: CGFloat = 20
    static let gap: CGFloat = 8

    struct Content {
        var original: String
        var translation: String
        var hint: String?
        var paused: Bool
        var mode: DisplayMode
        var lines: Int
        var fontSize: CGFloat
        var centered: Bool
        var color: SubtitleColor
    }

    struct Layout {
        let mainFont: UIFont
        let secondaryFont: UIFont
        let mainLine: CGFloat
        let secondaryLine: CGFloat
        let secondaryLines: Int
        let height: CGFloat

        init(mode: DisplayMode, lines: Int, fontSize: CGFloat) {
            mainFont = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            secondaryFont = UIFont.systemFont(ofSize: (fontSize * 0.72).rounded(), weight: .regular)
            mainLine = OverlayRenderer.lineHeight(mainFont)
            secondaryLine = OverlayRenderer.lineHeight(secondaryFont)
            secondaryLines = mode == .both ? (lines <= 2 ? 1 : 2) : 0
            var h = OverlayRenderer.padV * 2 + CGFloat(lines) * mainLine
            if secondaryLines > 0 { h += CGFloat(secondaryLines) * secondaryLine + OverlayRenderer.gap }
            height = ceil(h)
        }
    }

    /// Kutunun en/boy oranı (önizleme için).
    static func aspect(mode: DisplayMode, lines: Int, fontSize: CGFloat) -> CGFloat {
        width / Layout(mode: mode, lines: lines, fontSize: fontSize).height
    }

    static func lineHeight(_ f: UIFont) -> CGFloat { (f.lineHeight * 1.06).rounded() }

    func render(_ c: Content) -> CVPixelBuffer? {
        let layout = Layout(mode: c.mode, lines: c.lines, fontSize: c.fontSize)
        let w = Int(Self.width)
        let h = max(64, (Int(layout.height) + 1) & ~1)
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

        let inner = CGRect(x: Self.padH, y: Self.padV,
                           width: CGFloat(w) - Self.padH * 2, height: CGFloat(h) - Self.padV * 2)
        let mainColor: UIColor = c.color == .yellow ? UIColor(red: 1, green: 0.86, blue: 0.2, alpha: 1) : .white
        let grey = UIColor(white: 0.62, alpha: 1)

        let mainText = c.mode == .original ? c.original : c.translation
        let nothingToShow = mainText.isEmpty && (c.mode != .both || c.original.isEmpty)
        if let hint = c.hint, nothingToShow {
            drawHint(hint, maxSize: c.fontSize * 0.85, in: inner)
        } else {
            var mainRect = inner
            if layout.secondaryLines > 0 {
                let oRect = CGRect(x: inner.minX, y: inner.minY, width: inner.width,
                                   height: CGFloat(layout.secondaryLines) * layout.secondaryLine)
                drawTail(c.original, font: layout.secondaryFont, color: grey, in: oRect,
                         bottomAligned: false, centered: c.centered, ctx: ctx)
                mainRect = CGRect(x: inner.minX, y: oRect.maxY + Self.gap,
                                  width: inner.width, height: inner.maxY - oRect.maxY - Self.gap)
            }
            drawTail(mainText, font: layout.mainFont, color: mainColor, in: mainRect,
                     bottomAligned: c.mode != .both, centered: c.centered, ctx: ctx)
        }

        if c.paused {
            let size = min(34, CGFloat(h) * 0.3)
            let s = NSAttributedString(string: "⏸", attributes: [
                .font: UIFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: UIColor.systemYellow,
            ])
            s.draw(at: CGPoint(x: CGFloat(w) - size - 18, y: 4))
        }
        return pb
    }

    /// Bilgi yazısını kutuya sığana kadar küçülterek ortalar.
    private func drawHint(_ hint: String, maxSize: CGFloat, in rect: CGRect) {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        var size = maxSize
        var s = NSAttributedString()
        var b = CGRect.zero
        repeat {
            s = NSAttributedString(string: hint, attributes: [
                .font: UIFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: UIColor(white: 0.85, alpha: 1), .paragraphStyle: p,
            ])
            b = s.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            size -= 3
        } while b.height > rect.height && size > 16
        s.draw(with: CGRect(x: rect.minX, y: rect.midY - b.height / 2, width: rect.width, height: ceil(b.height)),
               options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }

    /// Metni kutuya sığdırır; taşarsa en yeni (alttaki) satırlar görünür.
    private func drawTail(_ text: String, font: UIFont, color: UIColor, in rect: CGRect,
                          bottomAligned: Bool, centered: Bool, ctx: CGContext) {
        guard !text.isEmpty, rect.height > 0 else { return }
        let lh = Self.lineHeight(font)
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lh
        p.maximumLineHeight = lh
        p.lineBreakMode = .byWordWrapping
        p.alignment = centered ? .center : .natural
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
        let b = s.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let textH = ceil(b.height / lh) * lh
        let lines = max(1, floor(rect.height / lh + 0.01))
        let visibleH = lines * lh
        var y = rect.minY - max(0, textH - visibleH)
        if bottomAligned && textH < visibleH { y = rect.minY + (visibleH - textH) }
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
    /// Kutudaki ⏩ (true) / ⏪ (false) düğmesine basıldı.
    var onSkip: ((Bool) -> Void)?

    /// ⏪ ⏩ düğmeleri gösterilsin mi (satır sayısını değiştirmek için).
    var showsSkipButtons: Bool {
        get { !(controller?.requiresLinearPlayback ?? true) }
        set {
            controller?.requiresLinearPlayback = !newValue
            controller?.invalidatePlaybackState()
        }
    }

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
        let seconds = CMTimeGetSeconds(skipInterval)
        if seconds.isFinite && seconds != 0 { onSkip?(seconds > 0) }
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
