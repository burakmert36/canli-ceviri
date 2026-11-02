import XCTest
@testable import CanliCeviri

/// Ekrandaki altyazıyı okuma: dikey/yatay alanlar, döndürülmüş kareler, değişmeyen kareyi atlama, hareket bölgesi.
final class OCRTests: XCTestCase {
    private let pw = 600, ph = 1300   // dikey kare (iPhone oranı)

    private func portraitFrame(caption: String, title: String) -> ScreenFrame {
        // Dikey YouTube: üstte video (altyazı videonun içinde), altta başlık
        let px = FakeScreen.gray(width: pw, height: ph, texts: [(caption, 0.29), (title, 0.45)])
        return ScreenFrame(width: pw, height: ph, orientation: .up, pixels: px, time: Date())
    }

    /// Yatay (tam ekran) video: dik hâli 1300×600; ham kare saat yönünde döndürülmüş, yön .left
    private func landscapeFrame(caption: String, top: String) -> ScreenFrame {
        let upright = FakeScreen.gray(width: ph, height: pw, texts: [(top, 0.05), (caption, 0.8)])
        let raw = FakeScreen.rotateCW(upright, width: ph, height: pw)
        return ScreenFrame(width: pw, height: ph, orientation: .left, pixels: raw, time: Date())
    }

    private func read(_ reader: ScreenTextReader, _ f: ScreenFrame, area: CGRect) -> String {
        let exp = expectation(description: "ocr")
        var text = ""
        reader.recognizeOnce(f, area: area, sourceLang: "en-US") { lines in
            text = lines.map { $0.text }.joined(separator: " ")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 60)   // sanitizer altında yazı tanıma çok yavaşlayabilir
        return text.lowercased()
    }

    func testPortraitAreaReadsCaptionButNotTitle() {
        let reader = ScreenTextReader()
        let f = portraitFrame(caption: "This is the caption line", title: "Amazing video title here")
        XCTAssertFalse(f.isLandscape)
        let t = read(reader, f, area: AppSettings.defaultPortraitArea)
        XCTAssertTrue(t.contains("caption"), "Okunan: \(t)")
        XCTAssertFalse(t.contains("amazing"), "Başlık alan dışında kalmalı: \(t)")
    }

    func testLandscapeRotatedFrameUsesUprightCoordinates() {
        let reader = ScreenTextReader()
        let f = landscapeFrame(caption: "Where are we going tonight", top: "Settings menu open")
        XCTAssertTrue(f.isLandscape)
        let img = ScreenTextReader.image(from: f)
        XCTAssertEqual(img?.size.width, CGFloat(ph))
        XCTAssertEqual(img?.size.height, CGFloat(pw))
        let t = read(reader, f, area: AppSettings.defaultLandscapeArea)
        XCTAssertTrue(t.contains("going"), "Okunan: \(t)")
        XCTAssertFalse(t.contains("settings"), "Üstteki yazı alan dışında: \(t)")
    }

    func testSubmitPicksAreaByOrientation() {
        let reader = ScreenTextReader()
        reader.configure(portrait: AppSettings.defaultPortraitArea, landscape: AppSettings.defaultLandscapeArea,
                         auto: false, sourceLang: "en-US")
        var results: [String] = []
        reader.onResult = { lines, _ in results.append(lines.map { $0.text }.joined(separator: " ").lowercased()) }
        reader.submit(portraitFrame(caption: "Portrait subtitle text", title: "Landscape title words"))
        XCTAssertTrue(waitUntil(20) { results.count == 1 })
        reader.submit(landscapeFrame(caption: "Landscape subtitle text", top: "Portrait header words"))
        XCTAssertTrue(waitUntil(20) { results.count == 2 })
        XCTAssertTrue(results[0].contains("portrait subtitle"), results[0])
        XCTAssertTrue(results[1].contains("landscape subtitle"), results[1])
    }

    func testUnchangedFrameIsNotReadTwice() {
        let reader = ScreenTextReader()
        reader.configure(portrait: AppSettings.defaultPortraitArea, landscape: AppSettings.defaultLandscapeArea,
                         auto: false, sourceLang: "en-US")
        var results: [[OCRLine]] = []
        reader.onResult = { lines, _ in results.append(lines) }
        let f = portraitFrame(caption: "Same caption again", title: "x")
        reader.submit(f)
        XCTAssertTrue(waitUntil(20) { results.count == 1 })
        reader.submit(f)
        XCTAssertTrue(waitUntil(20) { results.count == 2 })
        XCTAssertFalse(results[0].isEmpty)
        XCTAssertTrue(results[1].isEmpty, "Değişmeyen kare tekrar okunmamalı (pil)")
    }

    func testBusyReaderDropsFramesInsteadOfQueueing() {
        let reader = ScreenTextReader()
        reader.configure(portrait: CGRect(x: 0, y: 0, width: 1, height: 1), landscape: CGRect(x: 0, y: 0, width: 1, height: 1),
                         auto: false, sourceLang: "en-US")
        var count = 0
        reader.onResult = { _, _ in count += 1 }
        let f = portraitFrame(caption: "Busy test", title: "Lots of text to read here")
        for _ in 0..<50 { reader.submit(f) }
        spin(3)
        XCTAssertLessThan(count, 5, "Meşgulken gelen kareler sıraya alınmamalı (bellek ve pil)")
    }

    // MARK: Döndürme kilidi: iOS "dikey" der ama YouTube tam ekranı yatay çizer (v3.4)

    /// Yatay tam ekran video, ama iOS kareyi dikey (.up) etiketliyor.
    private func lockedLandscapeFrame(caption: String, clockwise: Bool = true) -> ScreenFrame {
        let upright = FakeScreen.gray(width: ph, height: pw, texts: [(caption, 0.8)], fontSize: 32)
        let raw = clockwise ? FakeScreen.rotateCW(upright, width: ph, height: pw)
                            : FakeScreen.rotateCCW(upright, width: ph, height: pw)
        return ScreenFrame(width: pw, height: ph, orientation: .up, pixels: raw, time: Date())
    }

    private func submitUntil(_ reader: ScreenTextReader, _ make: () -> ScreenFrame, tries: Int = 6,
                             until done: (String) -> Bool) -> String {
        var last = ""
        var results = 0
        reader.onResult = { lines, _ in last = lines.map { $0.text }.joined(separator: " ").lowercased(); results += 1 }
        for _ in 0..<tries {
            let before = results
            reader.submit(make())
            _ = waitUntil(40) { results > before }
            if done(last) { return last }
            spin(1.1)   // yön kararı belirsizse 1 sn sonra yeniden yoklanır
        }
        return last
    }

    func testRotationLockedLandscapeIsDetectedAndRead() {
        for clockwise in [true, false] {
            let reader = ScreenTextReader()
            reader.configure(portrait: AppSettings.defaultPortraitArea, landscape: AppSettings.defaultLandscapeArea,
                             auto: false, sourceLang: "en-US", probeOrientation: true)
            var n = 0
            let text = submitUntil(reader, {
                n += 1
                return lockedLandscapeFrame(caption: n % 2 == 0 ? "We have to leave this city tonight before the storm"
                                                                : "We have to leave this city tonight before the storm!",
                                            clockwise: clockwise)
            }, until: { $0.contains("city") })
            XCTAssertTrue(text.contains("city"), "Yatay altyazı okunmalı (saat yönü: \(clockwise)): \(text)")
            XCTAssertEqual(reader.resolvedOrientation, clockwise ? .left : .right)
            let resolved = reader.resolve(lockedLandscapeFrame(caption: "x", clockwise: clockwise))
            XCTAssertTrue(resolved.isLandscape, "Gerçek yön yatay olmalı")
        }
    }

    func testPortraitContentStaysPortrait() {
        let reader = ScreenTextReader()
        reader.configure(portrait: AppSettings.defaultPortraitArea, landscape: AppSettings.defaultLandscapeArea,
                         auto: false, sourceLang: "en-US", probeOrientation: true)
        let text = submitUntil(reader, { portraitFrame(caption: "Portrait caption is here", title: "Some channel title text") },
                               tries: 3, until: { $0.contains("portrait") })
        XCTAssertTrue(text.contains("portrait"), text)
        XCTAssertNotEqual(reader.resolvedOrientation, .left)
        XCTAssertNotEqual(reader.resolvedOrientation, .right)
    }

    func testProbeDisabledInCameraModeKeepsReportedOrientation() {
        let reader = ScreenTextReader()
        reader.configure(portrait: CGRect(x: 0, y: 0, width: 1, height: 1), landscape: CGRect(x: 0, y: 0, width: 1, height: 1),
                         auto: false, sourceLang: "en-US", probeOrientation: false)
        let f = lockedLandscapeFrame(caption: "Camera mode keeps orientation")
        var got: ScreenFrame?
        reader.onResult = { _, frame in got = frame }
        reader.submit(f)
        XCTAssertTrue(waitUntil(20) { got != nil })
        XCTAssertEqual(got?.orientation, .up)
        XCTAssertNil(reader.resolvedOrientation)
    }

    func testClampHandlesInvalidRects() {
        let bad: [CGRect] = [
            CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1),
            CGRect(x: -5, y: -5, width: 20, height: 20),
            CGRect(x: 2, y: 2, width: 0.1, height: 0.1),
            CGRect(x: 0.5, y: 0.5, width: 0, height: 0),
            CGRect.null,
        ]
        for r in bad {
            let c = ScreenTextReader.clamp(r)
            XCTAssertTrue(c.minX >= 0 && c.minY >= 0 && c.maxX <= 1.0001 && c.maxY <= 1.0001, "\(r) → \(c)")
            XCTAssertTrue(c.width >= 0.0499 && c.height >= 0.0499, "\(r) → \(c)")
        }
    }

    func testOrientationTransformsRoundTrip() {
        var g = SeededRandom(seed: 3)
        let orientations: [CGImagePropertyOrientation] = [.up, .down, .left, .right, .upMirrored, .leftMirrored, .rightMirrored, .downMirrored]
        for _ in 0..<500 {
            let x = CGFloat(g.int(0..<80)) / 100, y = CGFloat(g.int(0..<80)) / 100
            let r = CGRect(x: x, y: y, width: CGFloat(g.int(1..<20)) / 100, height: CGFloat(g.int(1..<20)) / 100)
            for o in orientations {
                let back = MotionRegionDetector.raw(fromOriented: MotionRegionDetector.oriented(r, o), o)
                XCTAssertEqual(back.minX, r.minX, accuracy: 1e-9)
                XCTAssertEqual(back.minY, r.minY, accuracy: 1e-9)
                XCTAssertEqual(back.width, r.width, accuracy: 1e-9)
                XCTAssertEqual(back.height, r.height, accuracy: 1e-9)
            }
        }
    }

    func testMotionDetectorFindsPlayingVideoRegion() {
        let d = MotionRegionDetector()
        var region: CGRect?
        for i in 0..<25 {
            // Üstte (0.05–0.35) sürekli değişen video, altta sabit yazılar
            var px = FakeScreen.gray(width: pw, height: ph, texts: [("Static title", 0.5), ("Comments 1.2K", 0.7)])
            var g = SeededRandom(seed: UInt64(i))
            // Gerçek video gibi bitişik bir bölge: yumuşak geçişli, her karede değişen parlaklık bulutları
            let y0 = Int(0.05 * Double(ph)), y1 = Int(0.35 * Double(ph))
            let phase = Int(g.next() % 64)
            for y in y0..<y1 {
                for x in 0..<pw {
                    px[y * pw + x] = UInt8(truncatingIfNeeded: ((x + phase * 3) / 7 + (y + phase) / 5) * 9 + phase)
                }
            }
            region = d.update(ScreenFrame(width: pw, height: ph, orientation: .up, pixels: px, time: Date()))
        }
        guard let r = region else { XCTFail("Video bölgesi bulunamadı"); return }
        XCTAssertLessThan(r.minY, 0.12, "\(r)")
        XCTAssertGreaterThan(r.maxY, 0.3, "\(r)")
        XCTAssertLessThan(r.maxY, 0.48, "Sabit başlık bölgeye girmemeli: \(r)")
    }

    func testAutoModeReadsInsideDetectedVideo() {
        let reader = ScreenTextReader()
        reader.configure(portrait: .zero, landscape: .zero, auto: true, sourceLang: "en-US")
        var all: [String] = []
        reader.onResult = { lines, _ in all.append(lines.map { $0.text }.joined(separator: " ").lowercased()) }
        for i in 0..<20 {
            // Video 0.05–0.30 arasında oynuyor; altyazı videonun alt kısmında (0.205), sabit başlık aşağıda
            var px = FakeScreen.gray(width: pw, height: ph, texts: [("Moving video caption", 0.205), ("Fixed heading", 0.6)])
            var g = SeededRandom(seed: UInt64(100 + i))
            let bands = [Int(0.05 * Double(ph))..<Int(0.20 * Double(ph)), Int(0.26 * Double(ph))..<Int(0.30 * Double(ph))]
            for band in bands {
                for y in band {
                    for x in 0..<pw where (x / 20 + y / 20) % 3 == 0 { px[y * pw + x] = UInt8(truncatingIfNeeded: g.next()) }
                }
            }
            let before = all.count
            reader.submit(ScreenFrame(width: pw, height: ph, orientation: .up, pixels: px, time: Date()))
            XCTAssertTrue(waitUntil(20) { all.count > before })
        }
        let text = all.joined(separator: " | ")
        XCTAssertFalse(text.contains("heading"), "Sabit yazı okunmamalı: \(text)")
        XCTAssertTrue(text.contains("caption") || text.contains("moving"), "Video içindeki altyazı okunmalı: \(text)")
    }

    /// Stres: rastgele boyut, yön ve alanlarla okuma — çökmemeli.
    func testRandomFramesStress() {
        let reader = ScreenTextReader()
        var g = SeededRandom(seed: 99)
        let orientations: [CGImagePropertyOrientation] = [.up, .down, .left, .right]
        for i in 0..<20 {
            let w = g.int(9..<900), h = g.int(9..<1400)
            let px = FakeScreen.gray(width: w, height: h, texts: [("Line \(i) hello", 0.4)], fontSize: CGFloat(g.int(8..<60)),
                                     noiseSeed: i)
            let f = ScreenFrame(width: w, height: h, orientation: orientations[g.int(0..<4)], pixels: px, time: Date())
            let area = CGRect(x: CGFloat(g.int(-20..<100)) / 100, y: CGFloat(g.int(-20..<100)) / 100,
                              width: CGFloat(g.int(0..<150)) / 100, height: CGFloat(g.int(0..<150)) / 100)
            _ = read(reader, f, area: area)
            _ = ScreenTextReader.image(from: f)
        }
    }
}
