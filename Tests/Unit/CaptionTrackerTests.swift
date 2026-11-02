import XCTest
@testable import CanliCeviri

/// Altyazı ayıklama: arayüz yazılarını eleme, kayan altyazıyı birleştirme.
final class CaptionTrackerTests: XCTestCase {
    private func line(_ t: String) -> OCRLine { OCRLine(text: t, box: CGRect(x: 0, y: 0, width: 1, height: 0.1)) }

    func testBaselineTextIsIgnoredNewTextIsReturned() {
        let c = CaptionTracker()
        let t0 = Date()
        XCTAssertEqual(c.dynamicLines([line("Menu label stays")], exclude: "", now: t0), [])
        let r = c.dynamicLines([line("Menu label stays"), line("Hello there friend")], exclude: "", now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(r, ["Hello there friend"])
    }

    func testTextThatReappearsIsTreatedAsInterface() {
        let c = CaptionTracker()
        let t0 = Date()
        _ = c.dynamicLines([], exclude: "", now: t0)
        XCTAssertEqual(c.dynamicLines([line("Chapter one intro")], exclude: "", now: t0.addingTimeInterval(1)), ["Chapter one intro"])
        // kaybolur…
        _ = c.dynamicLines([], exclude: "", now: t0.addingTimeInterval(4))
        // …ve aynen geri gelirse altyazı değil arayüzdür
        XCTAssertEqual(c.dynamicLines([line("Chapter one intro")], exclude: "", now: t0.addingTimeInterval(9)), [])
        XCTAssertEqual(c.dynamicLines([line("Chapter one intro")], exclude: "", now: t0.addingTimeInterval(9.5)), [])
    }

    func testTextStayingTooLongStopsBeingCaption() {
        let c = CaptionTracker()
        let t0 = Date()
        _ = c.dynamicLines([], exclude: "", now: t0)
        for s in stride(from: 1.0, through: 12.0, by: 1.0) {
            XCTAssertEqual(c.dynamicLines([line("Pinned banner text")], exclude: "", now: t0.addingTimeInterval(s)).count, 1)
        }
        XCTAssertEqual(c.dynamicLines([line("Pinned banner text")], exclude: "", now: t0.addingTimeInterval(14)), [])
    }

    func testOwnBoxTextIsExcluded() {
        let c = CaptionTracker()
        _ = c.dynamicLines([], exclude: "")
        let own = CaptionTracker.normalize("Merhaba nasılsın bugün")
        XCTAssertEqual(c.dynamicLines([line("Merhaba nasılsın"), line("Real caption")], exclude: own), ["Real caption"])
    }

    func testInterfaceHeuristics() {
        let ui = ["2:27 / 18:27", "70.487 görüntüleme", "1,5 B", "@kanaladi", "#shorts", "7 sa. önce", "Abone ol",
                  "Subscribe", "Skip Ad", "https://example.com", "Amazing video title that got cut…", "12K views", "", " ", "x"]
        for t in ui { XCTAssertTrue(CaptionTracker.looksLikeInterface(t), "Arayüz sayılmalı: \(t)") }
        let captions = ["I can't believe you did that", "Bugün hava çok güzel", "We need 3 more people",
                        "Where are you going?", "Это очень хорошо", "これはペンです"]
        for t in captions { XCTAssertFalse(CaptionTracker.looksLikeInterface(t), "Altyazı sayılmalı: \(t)") }
    }

    func testRollUpCaptionsMergeWithoutDuplicates() {
        let c = CaptionTracker()
        var live: [String] = []
        func feed(_ s: String) { live += c.newWords(caption: s, liveWords: live) }
        feed("hello how are")
        feed("how are you doing")
        feed("you doing today my friend")
        XCTAssertEqual(live.joined(separator: " "), "hello how are you doing today my friend")
        // Aynı satır tekrar okunursa hiçbir şey eklenmez
        XCTAssertEqual(c.newWords(caption: "how are you doing", liveWords: live), [])
    }

    func testOCRTypoToleranceInOverlap() {
        let c = CaptionTracker()
        var live = c.newWords(caption: "the quick brown", liveWords: [])
        // OCR "brown" kelimesini "brovn" okudu: yine örtüşme sayılmalı
        live += c.newWords(caption: "quick brovn fox jumps", liveWords: live)
        XCTAssertEqual(live.joined(separator: " "), "the quick brown fox jumps")
    }

    func testTailAfterCommitPreventsRepeats() {
        let c = CaptionTracker()
        let first = c.newWords(caption: "this is the first sentence", liveWords: [])
        c.commit(words: first.map(CaptionTracker.normalizeWord))
        // Yeni segment başladı; ekranda hâlâ eski satırın sonu duruyor
        XCTAssertEqual(c.newWords(caption: "first sentence", liveWords: []), [])
        XCTAssertEqual(c.newWords(caption: "first sentence and more", liveWords: []), ["and", "more"])
    }

    func testSingleWordCoincidenceIsNotOverlap() {
        let c = CaptionTracker()
        let live = ["I", "saw", "the"]
        XCTAssertEqual(c.newWords(caption: "the end is near", liveWords: live), ["the", "end", "is", "near"])
    }

    func testFuzzNeverCrashes() {
        var g = SeededRandom(seed: 5)
        let alphabet = Array("abcçdefgğhıijklmnoöprsştuüvyz ABC.,!?…@#:/0123456789😀🇹🇷日本語עברית")
        let c = CaptionTracker()
        var live: [String] = []
        var t = Date()
        for _ in 0..<3000 {
            let n = g.int(0..<60)
            let s = String((0..<n).map { _ in alphabet[g.int(0..<alphabet.count)] })
            _ = CaptionTracker.looksLikeInterface(s)
            _ = c.dynamicLines([line(s), line(String(s.reversed()))], exclude: g.int(0..<4) == 0 ? CaptionTracker.normalize(s) : "", now: t)
            live += c.newWords(caption: s, liveWords: live)
            if live.count > 60 { c.commit(words: live.map(CaptionTracker.normalizeWord)); live = [] }
            t = t.addingTimeInterval(Double(g.int(0..<2000)) / 1000)
        }
    }

    func testPerformanceOfLongRollUp() {
        let c = CaptionTracker()
        let words = (0..<400).map { "word\($0 % 37)x\($0)" }
        measure {
            var live: [String] = []
            for i in stride(from: 0, to: words.count - 8, by: 3) {
                live += c.newWords(caption: words[i..<(i + 8)].joined(separator: " "), liveWords: live)
            }
        }
    }
}
