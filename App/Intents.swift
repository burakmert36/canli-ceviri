import Foundation
import AppIntents
import SwiftUI
import Vision
import UIKit

enum AppTab: Hashable, CaseIterable {
    case screen, camera, history, settings

    var title: String {
        switch self {
        case .screen: return "Ekran"
        case .camera: return "Kamera"
        case .history: return "Geçmiş"
        case .settings: return "Ayarlar"
        }
    }
    var icon: String {
        switch self {
        case .screen: return "pip"
        case .camera: return "camera.viewfinder"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

/// Hangi sekmenin açık olduğunu tutar (kısayollar da buradan yönlendirir).
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    @Published var tab: AppTab = .screen
}

// MARK: - Kısayollar (Siri, Kestirmeler, iPhone Eylem Düğmesi)

struct StartScreenTranslationIntent: AppIntent {
    static let title: LocalizedStringResource = "Ekran Çevirisini Başlat"
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.tab = .screen
        try? await Task.sleep(nanoseconds: 700_000_000)
        if Engine.shared.running && Engine.shared.runMode == .camera { Engine.shared.stop() }
        Engine.shared.start()
        return .result()
    }
}

struct StartCameraTranslationIntent: AppIntent {
    static let title: LocalizedStringResource = "Kamera Çevirisini Başlat"
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.tab = .camera
        try? await Task.sleep(nanoseconds: 900_000_000)
        if Engine.shared.running && Engine.shared.runMode == .screen { Engine.shared.stop() }
        Engine.shared.startCamera()
        return .result()
    }
}

struct StopTranslationIntent: AppIntent {
    static let title: LocalizedStringResource = "Çeviriyi Durdur"
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        Engine.shared.stop()
        return .result()
    }
}

/// Dil çiftini değiştirir (ör. İngilizce→Türkçe ⇄ Almanca→Türkçe). iPhone 17'nin Eylem Düğmesi'ne atanabilir.
struct SwitchLanguageIntent: AppIntent {
    static let title: LocalizedStringResource = "Çeviri Dilini Değiştir"
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let p = Engine.shared.switchLanguagePair(forward: true) else {
            return .result(dialog: "Geçilecek başka dil çifti yok. Uygulamada birkaç farklı dil çifti kullan.")
        }
        return .result(dialog: "\(p.title)")
    }
}

/// Çeviriyi duraklatır ya da sürdürür.
struct TogglePauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Çeviriyi Duraklat / Sürdür"
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard Engine.shared.running else { return .result(dialog: "Çeviri şu an çalışmıyor.") }
        Engine.shared.togglePause()
        if Engine.shared.paused { return .result(dialog: "Duraklatıldı") }
        return .result(dialog: "Devam ediyor")
    }
}

/// Bir görüntüdeki (ör. ekran görüntüsü) tüm yazıyı okur ve çevirir.
/// Kestirmeler'de "Ekran Görüntüsü Al" ile birlikte kullanılır; iPhone'un arkasına iki kez dokunarak çalıştırılabilir.
struct TranslateImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Görüntüdeki Yazıyı Çevir"
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Görüntü")
    var image: IntentFile

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = try ImageTextReader.read(image.data)
        guard !text.isEmpty else {
            return .result(value: "", dialog: "Görüntüde okunabilir yazı bulunamadı.")
        }
        var cfg = EngineConfig(AppSettings.shared)
        cfg.sourceLang = "auto"   // görüntüdeki dil önceden bilinmez
        if cfg.translator == .apple { cfg.translator = .google }
        let translated = try await TranslationService(config: cfg).translate(text, context: [])
        return .result(value: translated, dialog: "\(translated)")
    }
}

/// Tek bir görüntüdeki yazıları yukarıdan aşağıya okur (durum çubuğu saati, pil yüzdesi gibi yazılar elenir).
enum ImageTextReader {
    static func read(_ data: Data) throws -> String {
        guard let img = UIImage(data: data), let cg = img.cgImage else {
            throw APIError.unsupported("Görüntü açılamadı")
        }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        try handler.perform([req])
        let lines = (req.results ?? [])
            .sorted { a, b in
                if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 { return a.boundingBox.midY > b.boundingBox.midY }
                return a.boundingBox.minX < b.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !CaptionTracker.looksLikeInterface($0) || $0.count > 40 }
        return lines.joined(separator: "\n")
    }
}

struct CanliCeviriShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartScreenTranslationIntent(),
                    phrases: ["\(.applicationName) ile ekranı çevir", "Start \(.applicationName)"],
                    shortTitle: "Ekranı Çevir",
                    systemImageName: "captions.bubble")
        AppShortcut(intent: StartCameraTranslationIntent(),
                    phrases: ["\(.applicationName) kamerasını aç", "\(.applicationName) camera"],
                    shortTitle: "Kamera Çevirisi",
                    systemImageName: "camera.viewfinder")
        AppShortcut(intent: StopTranslationIntent(),
                    phrases: ["\(.applicationName) durdur", "Stop \(.applicationName)"],
                    shortTitle: "Çeviriyi Durdur",
                    systemImageName: "stop.circle")
        AppShortcut(intent: SwitchLanguageIntent(),
                    phrases: ["\(.applicationName) dilini değiştir", "Switch \(.applicationName) language"],
                    shortTitle: "Dili Değiştir",
                    systemImageName: "globe")
        AppShortcut(intent: TogglePauseIntent(),
                    phrases: ["\(.applicationName) duraklat", "Pause \(.applicationName)"],
                    shortTitle: "Duraklat / Sürdür",
                    systemImageName: "playpause.fill")
    }
}

// MARK: - Güncelleme denetimi

/// GitHub'daki en son sürümü kontrol eder.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let repo = "burakmert36/canli-ceviri"
    static let releasesURL = URL(string: "https://github.com/\(repo)/releases")!

    @Published private(set) var latestVersion: String?
    @Published private(set) var checking = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastChecked: Date?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var updateAvailable: Bool {
        guard let l = latestVersion else { return false }
        return Self.compare(l, currentVersion) > 0
    }

    func check() {
        guard !checking, let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        checking = true
        Task { [weak self] in
            var version: String?
            var failure: String?
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 15
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: req)
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let tag = obj?["tag_name"] as? String {
                    version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                } else {
                    failure = "Sürüm bilgisi alınamadı"
                }
            } catch {
                failure = "Bağlantı hatası: \(error.localizedDescription)"
            }
            let v = version, f = failure
            await MainActor.run {
                guard let self = self else { return }
                if let v = v { self.latestVersion = v }
                self.lastError = f
                self.lastChecked = Date()
                self.checking = false
            }
        }
    }

    /// "3.0.12" ile "3.0.9" gibi sürümleri sayısal karşılaştırır.
    static func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
