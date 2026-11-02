import XCTest
@testable import CanliCeviri

/// Geçmiş kaydı ve SRT dışa aktarma.
final class HistoryTests: XCTestCase {
    private let h = HistoryStore.shared
    private var snapshot: [HistoryEntry] = []

    override func setUp() {
        super.setUp()
        snapshot = h.entries
        h.clear()
    }

    override func tearDown() {
        h.clear()
        for e in snapshot { h.add(original: e.original, translation: e.translation, source: e.source) }
        super.tearDown()
    }

    func testAddUpdateDelete() {
        let a = h.add(original: "Hello", translation: "Merhaba", source: "Ekran altyazısı")
        let b = h.add(original: "Bye", translation: "", source: "Mikrofon")
        h.update(b, original: "Bye now", translation: "Hoşça kal")
        XCTAssertEqual(h.entries.last?.translation, "Hoşça kal")
        h.delete([a])
        XCTAssertEqual(h.entries.map(\.original), ["Bye now"])
        h.update(UUID(), original: "x", translation: "y")   // olmayan kayıt: sessizce yok sayılır
        XCTAssertEqual(h.entries.count, 1)
    }

    func testCapAt3000Entries() {
        for i in 0..<3100 { h.add(original: "o\(i)", translation: "t\(i)", source: "test") }
        XCTAssertEqual(h.entries.count, 3000)
        XCTAssertEqual(h.entries.first?.original, "o100")
    }

    func testSRTFormat() throws {
        h.add(original: "Hello", translation: "Merhaba", source: "test")
        h.add(original: "World", translation: "", source: "test")
        let url = try XCTUnwrap(h.exportSRT(h.entries))
        let srt = try String(contentsOf: url, encoding: .utf8)
        let blocks = srt.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks[0].hasPrefix("1\n00:00:00,000 --> 00:00:0"))
        XCTAssertTrue(blocks[0].contains("Merhaba\nHello"))
        XCTAssertTrue(blocks[1].contains("World"))
        let timing = try NSRegularExpression(pattern: #"^\d+\n\d\d:\d\d:\d\d,\d\d\d --> \d\d:\d\d:\d\d,\d\d\d\n"#)
        for b in blocks {
            XCTAssertNotNil(timing.firstMatch(in: b, range: NSRange(b.startIndex..., in: b)), b)
        }
        XCTAssertNil(h.exportSRT([]))
    }

    func testExportTextAndLastSession() {
        h.add(original: "A", translation: "B", source: "Kamera")
        let text = h.exportText(h.entries)
        XCTAssertTrue(text.contains("Kamera"))
        XCTAssertTrue(text.contains("→ B"))
        XCTAssertEqual(h.lastSession().count, 1)
    }

    func testConcurrentAddsFromMainAreSafe() {
        // Engine geçmişe yalnızca ana iş parçacığından yazar; hızlı ardışık eklemeler kaydı bozmamalı.
        measure {
            for i in 0..<500 { h.add(original: "line \(i)", translation: "satır \(i)", source: "stres") }
        }
        XCTAssertLessThanOrEqual(h.entries.count, 3000)
    }
}
