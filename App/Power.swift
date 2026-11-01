import Foundation
import Combine

/// Pil tasarrufu tercihi.
enum BatteryMode: String, CaseIterable, Identifiable {
    case auto, always, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Otomatik"
        case .always: return "Her zaman"
        case .off: return "Kapalı"
        }
    }
}

/// iPhone/iPad'in Düşük Güç modu ve ısı durumunu izler; uygulama buna göre kendini kısar.
final class PowerMonitor: ObservableObject {
    static let shared = PowerMonitor()

    @Published private(set) var lowPowerMode: Bool
    @Published private(set) var thermal: ProcessInfo.ThermalState

    private init() {
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermal = ProcessInfo.processInfo.thermalState
        let nc = NotificationCenter.default
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.thermal = ProcessInfo.processInfo.thermalState
        }
    }

    var isHot: Bool { thermal == .serious || thermal == .critical }
    var isCritical: Bool { thermal == .critical }

    var thermalTitle: String {
        switch thermal {
        case .nominal: return "Normal"
        case .fair: return "Ilık"
        case .serious: return "Sıcak"
        case .critical: return "Çok sıcak"
        @unknown default: return "Bilinmiyor"
        }
    }

    /// Tasarruf şu an etkin mi? (Kapalı seçilse bile aşırı ısınmada cihazı korumak için devreye girer.)
    func saving(_ mode: BatteryMode) -> Bool {
        switch mode {
        case .always: return true
        case .off: return isCritical
        case .auto: return lowPowerMode || isHot
        }
    }
}
