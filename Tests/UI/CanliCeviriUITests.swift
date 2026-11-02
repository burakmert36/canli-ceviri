import XCTest
import UIKit

/// Arayüz çökme ve stres testleri (iPhone 17 simülatörü).
final class CanliCeviriUITests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Sistem izinleri") { alert in
            Self.allow(alert)
        }
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        if app.state != .notRunning { app.terminate() }
        super.tearDown()
    }

    @discardableResult
    private static func allow(_ alert: XCUIElement) -> Bool {
        let labels = ["Allow", "İzin Ver", "OK", "Tamam", "Allow While Using App", "Uygulamayı Kullanırken İzin Ver",
                      "Allow Once", "Bir Kez İzin Ver", "Allow Full Access"]
        for l in labels where alert.buttons[l].exists {
            alert.buttons[l].tap()
            return true
        }
        return false
    }

    /// Sistem uyarılarını (izinler) kapatır.
    private func handleSystemAlerts() {
        for _ in 0..<3 {
            let a = springboard.alerts.firstMatch
            guard a.exists else { return }
            if !Self.allow(a) {
                let n = a.buttons.count
                guard n > 0 else { return }
                a.buttons.element(boundBy: n - 1).tap()
            }
        }
    }

    private func launch(_ args: [String] = ["--skip-onboarding"]) {
        app.launchArguments = args
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    }

    private func assertAlive(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotEqual(app.state, .notRunning, "Uygulama çöktü: \(context)", file: file, line: line)
        if app.state != .runningForeground { app.activate() }
    }

    private func tab(_ name: String) {
        let b = app.buttons[name].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 5), "Sekme yok: \(name)")
        b.tap()
    }

    /// Form içinde bir öğeyi görünür olana kadar kaydırır.
    @discardableResult
    private func scrollTo(_ el: XCUIElement, maxSwipes: Int = 10, up: Bool = true) -> Bool {
        var n = 0
        while !(el.exists && el.isHittable) && n < maxSwipes {
            if up { app.swipeUp() } else { app.swipeDown() }
            n += 1
        }
        return el.exists && el.isHittable
    }

    // MARK: Testler

    func testOnboardingFlow() {
        launch(["--reset-settings"])
        let next = app.buttons["Devam"]
        XCTAssertTrue(next.waitForExistence(timeout: 8), "Tanıtım açılmalı")
        for _ in 0..<3 { if next.exists { next.tap() } }
        let go = app.buttons["Başlayalım"]
        XCTAssertTrue(go.waitForExistence(timeout: 5))
        go.tap()
        XCTAssertTrue(app.buttons["Ekran"].waitForExistence(timeout: 5))
        assertAlive("tanıtım")
    }

    func testTabCyclingStress() {
        launch()
        let tabs = ["Ekran", "Kamera", "Geçmiş", "Ayarlar"]
        for i in 0..<30 {
            tab(tabs[i % tabs.count])
            if i % 7 == 0 { handleSystemAlerts() }
        }
        assertAlive("sekme döngüsü")
    }

    func testAreaPickerInteractions() {
        launch()
        tab("Ekran")
        let readCaptions = app.buttons["Altyazıyı oku"].firstMatch
        XCTAssertTrue(readCaptions.waitForExistence(timeout: 5))
        readCaptions.tap()
        let manual = app.buttons["Seçtiğim alan"].firstMatch
        if scrollTo(manual) { manual.tap() }
        let open = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Altyazı alanını seç'")).firstMatch
        XCTAssertTrue(scrollTo(open), "Alan seçici düğmesi bulunamadı")
        for round in 0..<6 {
            open.tap()
            let done = app.buttons["Bitti"].firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 5), "Alan seçici açılmadı (tur \(round))")
            let landscape = app.buttons["Yatay / tam ekran"].firstMatch
            let portrait = app.buttons["Dikey video"].firstMatch
            (round % 2 == 0 ? landscape : portrait).tap()
            // Tuvalde köşe ve gövde sürüklemeleri
            let win = app.windows.firstMatch
            let pts: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (0.5, 0.35, 0.5, 0.25), (0.1, 0.2, 0.3, 0.3), (0.9, 0.5, 0.6, 0.55), (0.5, 0.5, 0.5, 0.9), (0.2, 0.6, 0.05, 0.1),
            ]
            for (x0, y0, x1, y1) in pts {
                let a = win.coordinate(withNormalizedOffset: CGVector(dx: x0, dy: y0))
                let b = win.coordinate(withNormalizedOffset: CGVector(dx: x1, dy: y1))
                a.press(forDuration: 0.05, thenDragTo: b)
            }
            if round == 3 { app.buttons["Varsayılan"].firstMatch.tap() }
            done.tap()
            XCTAssertTrue(open.waitForExistence(timeout: 5))
        }
        assertAlive("alan seçici")
    }

    /// Yatay kart şeridinde bir kartı görünür yapar.
    private func reveal(_ chip: XCUIElement) -> Bool {
        if chip.exists && chip.isHittable { return true }
        let row = app.scrollViews.containing(.button, identifier: "engine-google").firstMatch
        guard row.exists else { return false }
        for _ in 0..<3 where !chip.isHittable { row.swipeLeft() }
        for _ in 0..<4 where !chip.isHittable { row.swipeRight() }
        return chip.isHittable
    }

    func testEnginePickerAndProviderSheets() {
        launch()
        tab("Ekran")
        let google = app.buttons["engine-google"]
        XCTAssertTrue(google.waitForExistence(timeout: 5), "Çeviri motoru kartları yok")
        var n = 0
        while !google.isHittable && n < 6 { app.swipeUp(); n += 1 }
        for id in ["gemini", "openai", "claude", "google", "apple", "appleAI"] {
            let chip = app.buttons["engine-" + id]
            guard chip.exists, reveal(chip) else { XCTFail("Motor kartı yok/görünmüyor: \(id)"); continue }
            chip.tap()
            let done = app.buttons["Bitti"].firstMatch
            if done.waitForExistence(timeout: 2) {
                let field = app.secureTextFields.firstMatch
                if field.exists && field.isHittable {
                    field.tap()
                    field.typeText("abc")
                }
                done.tap()
                XCTAssertTrue(chip.waitForExistence(timeout: 3))
            }
            XCTAssertTrue(chip.isSelected, "\(id) seçilmiş olmalı")
            let configure = app.buttons["engine-configure"]
            if configure.exists && configure.isHittable {
                configure.tap()
                let d2 = app.buttons["Bitti"].firstMatch
                XCTAssertTrue(d2.waitForExistence(timeout: 3), "\(id) ayar sayfası açılmadı")
                if d2.exists { d2.tap() }
            }
        }
        // Google'a geri dön (sonraki testler için)
        if reveal(google) { google.tap() }
        assertAlive("motor seçimi")
    }

    func testRotationStress() {
        launch()
        let tabs = ["Ekran", "Kamera", "Geçmiş", "Ayarlar"]
        let orientations: [UIDeviceOrientation] = [.landscapeLeft, .portrait, .landscapeRight, .portrait]
        for i in 0..<12 {
            XCUIDevice.shared.orientation = orientations[i % orientations.count]
            tab(tabs[i % tabs.count])
            handleSystemAlerts()
        }
        XCUIDevice.shared.orientation = .portrait
        assertAlive("döndürme")
    }

    func testCameraModeOnDeviceWithoutCamera() {
        launch()
        tab("Kamera")
        handleSystemAlerts()
        app.tap()   // kesinti izleyicisini tetikle
        let start = app.buttons["Başlat"].firstMatch
        if scrollTo(start, maxSwipes: 4) {
            start.tap()
            sleep(2)
            handleSystemAlerts()
            let stop = app.buttons["Durdur"].firstMatch
            if stop.exists { stop.tap() }
        }
        // Mikrofon modu
        let listen = app.buttons["Konuşmayı dinle"].firstMatch
        if scrollTo(listen, maxSwipes: 4, up: false) || listen.exists {
            listen.tap()
            if scrollTo(start, maxSwipes: 4) {
                start.tap()
                for _ in 0..<3 { sleep(1); handleSystemAlerts(); app.tap() }
                let stop = app.buttons["Durdur"].firstMatch
                if stop.exists && stop.isHittable { stop.tap() }
            }
            let read = app.buttons["Altyazıyı oku"].firstMatch
            if read.exists && read.isHittable { read.tap() }
        }
        assertAlive("kamera modu")
    }

    func testScreenStartAndStop() {
        launch()
        tab("Ekran")
        let readCaptions = app.buttons["Altyazıyı oku"].firstMatch
        if readCaptions.waitForExistence(timeout: 5) { readCaptions.tap() }
        let start = app.buttons["Başlat"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        sleep(3)
        handleSystemAlerts()
        assertAlive("ekran çevirisi başlatma")
        // Sistem yayın penceresi açıldıysa kapat
        if app.state == .runningForeground {
            let stop = app.buttons["Durdur"].firstMatch
            if !(stop.exists && stop.isHittable) { app.swipeDown(velocity: .fast) }
            if stop.waitForExistence(timeout: 3) && stop.isHittable { stop.tap() }
        }
        assertAlive("ekran çevirisi durdurma")
    }

    /// Maymun testi: 3 dakikaya yakın rastgele dokunma/kaydırma/döndürme. Çökme sayılır.
    func testMonkey() {
        launch()
        var g = SystemRandomNumberGenerator()
        let orientations: [UIDeviceOrientation] = [.portrait, .landscapeLeft, .landscapeRight]
        var crashes = 0
        let started = Date()
        var events = 0
        while Date().timeIntervalSince(started) < 170 && events < 600 {
            events += 1
            if app.state == .notRunning {
                crashes += 1
                XCTFail("Uygulama \(events). olayda çöktü")
                launch()
                continue
            }
            if app.state != .runningForeground {
                app.activate()   // bağlantı/Safari/Kestirmeler açıldıysa geri dön
                _ = app.wait(for: .runningForeground, timeout: 5)
                continue
            }
            if events % 25 == 0 { handleSystemAlerts() }
            let roll = Int.random(in: 0..<100, using: &g)
            let win = app.windows.firstMatch
            let x = CGFloat.random(in: 0.04...0.96, using: &g)
            let y = CGFloat.random(in: 0.08...0.95, using: &g)
            let p = win.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
            switch roll {
            case 0..<70:
                p.tap()
            case 70..<85:
                let q = win.coordinate(withNormalizedOffset: CGVector(dx: CGFloat.random(in: 0.05...0.95, using: &g),
                                                                       dy: CGFloat.random(in: 0.1...0.9, using: &g)))
                p.press(forDuration: 0.05, thenDragTo: q)
            case 85..<92:
                app.swipeUp()
            case 92..<97:
                app.swipeDown()
            default:
                XCUIDevice.shared.orientation = orientations[Int.random(in: 0..<orientations.count, using: &g)]
            }
        }
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(crashes, 0, "\(events) olayda \(crashes) çökme")
        assertAlive("maymun testi")
    }

    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launchArguments = ["--skip-onboarding"]
            app.launch()
        }
    }

    func testMemoryWhileUsingTabs() {
        launch()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTMemoryMetric(application: app), XCTCPUMetric(application: app)], options: options) {
            for name in ["Ekran", "Kamera", "Geçmiş", "Ayarlar", "Ekran"] {
                tab(name)
                handleSystemAlerts()
            }
        }
        assertAlive("bellek ölçümü")
    }
}
