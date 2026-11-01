import Foundation
import AVFoundation

/// Çevirileri cihazın kendi sesleriyle okur (ücretsiz, internetsiz).
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var queued = 0
    private var lastEnd = Date.distantPast

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Konuşuyor ya da çok kısa süre önce bitirdi mi? (Kendi sesimizi tekrar dinlememek için)
    var isBusy: Bool { synth.isSpeaking || Date().timeIntervalSince(lastEnd) < 0.4 }

    /// Kulaklık/AirPods bağlı mı? (Bağlıysa hoparlörden yankı olmaz.)
    var headphonesConnected: Bool {
        let wired: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .usbAudio, .airPlay]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { wired.contains($0.portType) }
    }

    func speak(_ text: String, language: String, voiceID: String, rate: Float) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Video, okumadan hızlı ilerliyorsa eski cümleleri atla; hep en günceli oku.
        if queued >= 2 {
            synth.stopSpeaking(at: .word)
            queued = 0
        }
        let u = AVSpeechUtterance(string: t)
        u.voice = (voiceID.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: voiceID)) ?? Speaker.bestVoice(for: language)
        u.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(rate, AVSpeechUtteranceMaximumSpeechRate))
        u.postUtteranceDelay = 0.05
        queued += 1
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        queued = 0
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finished() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finished() }

    private func finished() {
        DispatchQueue.main.async {
            self.queued = max(0, self.queued - 1)
            self.lastEnd = Date()
        }
    }

    /// Bir dil için cihazdaki sesler (en kaliteliden başlayarak).
    static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        let prefix = (language.split(separator: "-").first.map(String.init) ?? language).lowercased()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(prefix) }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        voices(for: language).first ?? AVSpeechSynthesisVoice(language: language)
    }

    static func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "Premium"
        case .enhanced: return "Gelişmiş"
        default: return "Standart"
        }
    }
}
