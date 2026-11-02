import XCTest
import AVFoundation
@testable import CanliCeviri

/// Seslendirme ve video sesini kısma (ducking).
final class AudioSessionTests: XCTestCase {
    func testDuckingTogglesSessionOptions() throws {
        let k = KeepAlive()
        try k.start()
        defer { k.stop() }
        let session = AVAudioSession.sharedInstance()
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers))
        k.setDucking(true)
        XCTAssertTrue(k.ducking)
        XCTAssertTrue(session.categoryOptions.contains(.duckOthers))
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers), "Videonun sesi durmamalı, sadece kısılmalı")
        k.setDucking(false)
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers))
    }

    func testRapidDuckingStress() throws {
        let k = KeepAlive()
        try k.start()
        defer { k.stop() }
        for i in 0..<60 { k.setDucking(i % 2 == 0) }
        XCTAssertFalse(k.ducking)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
    }

    func testDuckingWhileInactiveIsDeferred() throws {
        let k = KeepAlive()
        k.setDucking(true)   // oturum kapalıyken sadece hatırlanır
        try k.start()
        XCTAssertTrue(AVAudioSession.sharedInstance().categoryOptions.contains(.duckOthers))
        k.stop()
        XCTAssertFalse(k.ducking, "Durunca kısma sıfırlanmalı")
    }

    func testSpeakerReportsBusyAndIdle() {
        let sp = Speaker()
        var events: [Bool] = []
        sp.onBusyChanged = { events.append($0) }
        sp.speak("Merhaba", language: "tr-TR", voiceID: "", rate: 0.6)
        XCTAssertEqual(events.first, true)
        // Simülatörde ses motoru yoksa okuma hemen biter ya da iptal edilir; her iki durumda da "boşta" bildirilmeli.
        _ = waitUntil(15) { events.last == false }
        sp.stop()
        XCTAssertEqual(events.last, false)
        XCTAssertLessThanOrEqual(events.count, 3)
    }

    func testSpeakerBacklogStressEndsIdle() {
        let sp = Speaker()
        var events: [Bool] = []
        sp.onBusyChanged = { events.append($0) }
        for i in 0..<50 { sp.speak("Cümle numarası \(i)", language: "tr-TR", voiceID: "", rate: 0.5) }
        sp.stop()
        spin(0.5)
        XCTAssertEqual(events.last, false, "Durdurunca boşta bildirilmeli: \(events)")
    }
}
