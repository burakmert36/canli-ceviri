import UIKit
import ReplayKit
import SwiftUI

/// Sistemin "Ekran Yayını" penceresini açar (ses yakalamayı başlatmak için).
enum BroadcastPicker {
    /// Uygulamanın içindeki yayın uzantısının paket kimliği (yeniden imzalamada değişse bile bulunur).
    static let extensionID: String? = {
        guard let url = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        else { return nil }
        for item in items where item.pathExtension == "appex" {
            guard let b = Bundle(url: item),
                  let ext = b.infoDictionary?["NSExtension"] as? [String: Any],
                  (ext["NSExtensionPointIdentifier"] as? String) == "com.apple.broadcast-services-upload"
            else { continue }
            return b.bundleIdentifier
        }
        return nil
    }()

    static let pickerView: RPSystemBroadcastPickerView = {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        v.showsMicrophoneButton = false
        v.preferredExtension = extensionID
        v.tintColor = .systemRed
        return v
    }()

    /// Yayın penceresini programla açar.
    static func present() {
        for case let button as UIButton in pickerView.subviews {
            button.sendActions(for: .allTouchEvents)
            return
        }
    }
}

struct BroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        let p = BroadcastPicker.pickerView
        p.removeFromSuperview()
        p.frame = container.bounds
        p.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(p)
        return container
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        let p = BroadcastPicker.pickerView
        if p.superview !== uiView {
            p.removeFromSuperview()
            p.frame = uiView.bounds
            uiView.addSubview(p)
        }
    }
}
