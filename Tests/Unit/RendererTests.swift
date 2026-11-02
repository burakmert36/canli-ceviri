import XCTest
import CoreVideo
@testable import CanliCeviri

/// Yüzen kutunun çizimi: tüm stil kombinasyonları, uç metinler, bellek ve hız.
final class RendererTests: XCTestCase {
    private func content(_ o: String, _ t: String, mode: DisplayMode = .both, lines: Int = 3, font: CGFloat = 58,
                         hint: String? = nil) -> OverlayRenderer.Content {
        OverlayRenderer.Content(original: o, translation: t, hint: hint, paused: false, mode: mode, lines: lines,
                                fontSize: font, centered: false, color: .white)
    }

    func testAllStyleCombinationsRender() {
        let r = OverlayRenderer()
        for mode in DisplayMode.allCases {
            for lines in AppSettings.linesRange {
                for style in FontStyleChoice.allCases {
                    for bold in [true, false] {
                        var c = content("Hello, how are you today?", "Merhaba, bugün nasılsın?", mode: mode, lines: lines)
                        c.fontStyle = style
                        c.bold = bold
                        c.background = BoxBackground.allCases[lines % BoxBackground.allCases.count]
                        c.color = SubtitleColor.allCases[lines % SubtitleColor.allCases.count]
                        c.centered = lines % 2 == 0
                        c.paused = bold
                        guard let pb = r.render(c) else { XCTFail("Çizilemedi: \(mode) \(lines) \(style)"); continue }
                        XCTAssertEqual(CVPixelBufferGetWidth(pb), Int(OverlayRenderer.width))
                        let expected = OverlayRenderer.Layout(mode: mode, lines: lines, fontSize: 58, style: style, bold: bold).height
                        XCTAssertEqual(Double(CVPixelBufferGetHeight(pb)), Double(max(64, expected)), accuracy: 2)
                        XCTAssertEqual(CVPixelBufferGetHeight(pb) % 2, 0, "Video kodlayıcı için çift yükseklik")
                    }
                }
            }
        }
    }

    func testExtremeTextsRender() {
        let r = OverlayRenderer()
        let texts = [
            "", " ", "\n\n\n", String(repeating: "W", count: 5000),
            String(repeating: "çok uzun bir cümle ", count: 400),
            "مرحبا كيف حالك اليوم؟ هذا نص عربي طويل", "שלום עולם", "日本語のテキストです。とても長い文章になります。",
            "😀🎮🔥🇹🇷👨‍👩‍👧‍👦", "\u{202E}tersine", "\0null\0", "Zalgo t̷̢̛͓̼̱e̴̡̮x̶̡͍t̸̢̛",
        ]
        for t in texts {
            for mode in DisplayMode.allCases {
                XCTAssertNotNil(r.render(content(t, t, mode: mode, lines: 2)), "metin: \(t.prefix(20))")
            }
        }
        XCTAssertNotNil(r.render(content("", "", hint: "Canlı Çeviri\nBaşlat'a dokun")))
        XCTAssertNotNil(r.render(content("", "", hint: String(repeating: "Uzun ipucu ", count: 200))))
    }

    func testFontSizeExtremes() {
        let r = OverlayRenderer()
        for size in [CGFloat(1), 8, 36, 100, 300] {
            for lines in [1, 8] {
                XCTAssertNotNil(r.render(content("Test", "Deneme", lines: lines, font: size)), "size \(size)")
            }
        }
    }

    /// Stres: 3000 kare, rastgele içerik — bellek sızıntısı olmamalı (tampon havuzu).
    func testRenderStressMemoryStaysFlat() {
        let r = OverlayRenderer()
        var g = SeededRandom(seed: 11)
        let words = ["merhaba", "dünya", "hello", "world", "çeviri", "altyazı", "🎮", "日本", "test", "GTA"]
        // Isınma
        for _ in 0..<50 { _ = r.render(content("warm", "up")) }
        let before = memoryFootprintMB()
        for i in 0..<3000 {
            autoreleasepool {
                let n = g.int(0..<60)
                let text = (0..<n).map { _ in words[g.int(0..<words.count)] }.joined(separator: " ")
                let mode = DisplayMode.allCases[i % 3]
                _ = r.render(content(text, String(text.reversed()), mode: mode, lines: 1 + i % 8, font: CGFloat(36 + i % 64)))
            }
        }
        assertMemoryGrowth(memoryFootprintMB() - before, below: 60, "3000 kutu çizimi")
    }

    func testRenderPerformance() {
        let r = OverlayRenderer()
        let c = content("Hey, welcome back! Today we're exploring the city and its hidden places.",
                        "Hey, tekrar hoş geldin! Bugün şehri ve gizli köşelerini keşfediyoruz.", lines: 3)
        measure {
            for _ in 0..<60 { _ = r.render(c) }
        }
    }

    func testPiPEnqueueStress() {
        let pip = PiPManager()
        let r = OverlayRenderer()
        for i in 0..<500 {
            if let pb = r.render(content("line \(i)", "satır \(i)", lines: 1 + i % 8)) { pip.enqueue(pb) }
        }
        pip.displayLayer.flush()
        XCTAssertNotEqual(pip.displayLayer.status, .failed)
    }

    func testAspectIsPositiveAndFinite() {
        for mode in DisplayMode.allCases {
            for lines in AppSettings.linesRange {
                for size in stride(from: 36.0, through: 100.0, by: 8.0) {
                    let a = OverlayRenderer.aspect(mode: mode, lines: lines, fontSize: CGFloat(size))
                    XCTAssertTrue(a.isFinite && a > 0.5 && a < 20, "\(mode) \(lines) \(size) → \(a)")
                }
            }
        }
    }
}
