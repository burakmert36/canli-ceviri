import Foundation
import Network
import ImageIO

/// Yayın uzantısından gelen gri tonlamalı ekran karesi.
struct ScreenFrame {
    let width: Int
    let height: Int
    let orientation: CGImagePropertyOrientation
    let pixels: Data   // width * height bayt, satır satır
    let time: Date

    /// Görüntü dik çevrildiğinde yatay mı? (ör. YouTube tam ekran)
    var isLandscape: Bool {
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored: return height > width
        default: return width > height
        }
    }
}

/// Yayın uzantısından gelen ses ve görüntüyü yalnızca 127.0.0.1 üzerinden dinler.
/// Mesaj biçimi: [tür 1 bayt][uzunluk 4 bayt LE][veri] — 'A' ses, 'F' ekran karesi.
/// Uzantıya giden tek baytlık komutlar: 'S' yayını kapat, 'V'/'W'/'v' görüntü sık/seyrek/kapalı, 'M'/'m' ses açık/kapalı.
final class AudioReceiver {
    static let port: UInt16 = 47321
    static let maxMessage = 16 * 1024 * 1024

    let port: UInt16

    init(port: UInt16 = AudioReceiver.port) {
        self.port = port
    }

    /// Ses örnekleri (alıcı kuyruğunda çağrılır).
    var onAudio: (([Int16]) -> Void)?
    /// Ekran karesi (alıcı kuyruğunda çağrılır).
    var onFrame: ((ScreenFrame) -> Void)?
    /// Uzantı bağlandı / koptu (alıcı kuyruğunda çağrılır).
    var onConnectionChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "canliceviri.receiver")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
    private var videoMode: VideoMode = .off
    private var audioEnabled = true

    /// Uzantıdan istenen ekran görüntüsü sıklığı.
    enum VideoMode {
        case off, fast, slow
        var command: String {
            switch self {
            case .off: return "v"
            case .fast: return "V"   // ~2,5 kare/sn (altyazı akarken)
            case .slow: return "W"   // ~1 kare/sn (altyazı yokken / pil tasarrufunda)
            }
        }
    }

    /// Dinlemeyi başlatır (zaten dinliyorsa bir şey yapmaz).
    func ensureListening() {
        queue.async { self.startListener() }
    }

    /// Uzantıdan ekran görüntüsü istenip istenmediğini ve sıklığını ayarlar.
    func setVideoMode(_ mode: VideoMode) {
        queue.async {
            self.videoMode = mode
            self.sendCommand(mode.command)
        }
    }

    /// Uzantının sesi işleyip gönderip göndermeyeceği (altyazı okurken ses gerekmez: pil tasarrufu).
    func setAudioEnabled(_ on: Bool) {
        queue.async {
            guard self.audioEnabled != on else { return }
            self.audioEnabled = on
            self.sendCommand(on ? "M" : "m")
        }
    }

    /// Dinlemeyi tamamen kapatır (testler için).
    func shutdown() {
        queue.sync {
            self.connection?.cancel()
            self.connection = nil
            let l = self.listener
            self.listener = nil
            l?.cancel()
            self.buffer.removeAll()
        }
    }

    /// Uzantıya "yayını kapat" komutu gönderir.
    func requestBroadcastStop() {
        queue.async { self.sendCommand("S") }
    }

    private func sendCommand(_ c: String) {
        guard let conn = connection else { return }
        conn.send(content: Data(c.utf8), completion: .contentProcessed { _ in })
    }

    private func startListener() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: self.port) else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params, on: port)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self = self else { return }
                switch state {
                case .failed, .cancelled:
                    if self.listener === l {
                        self.listener = nil
                        self.queue.asyncAfter(deadline: .now() + 1) { self.startListener() }
                    }
                default: break
                }
            }
            listener = l
            l.start(queue: queue)
        } catch {
            queue.asyncAfter(deadline: .now() + 1) { self.startListener() }
        }
    }

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        buffer.removeAll()
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if let c = conn, self.connection === c {
                    // Yeni bağlanan uzantıya güncel istekleri bildir.
                    if self.videoMode != .off { self.sendCommand(self.videoMode.command) }
                    if !self.audioEnabled { self.sendCommand("m") }
                }
                self.onConnectionChange?(true)
            case .failed, .cancelled:
                if let c = conn, self.connection === c {
                    self.connection = nil
                    self.buffer.removeAll()
                    self.onConnectionChange?(false)
                }
            default: break
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty, self.connection === conn {
                self.buffer.append(data)
                self.parse()
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(on: conn)
        }
    }

    private func parse() {
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 5 {
            let type = buffer[offset]
            let len = Int(buffer[offset + 1]) | Int(buffer[offset + 2]) << 8
                | Int(buffer[offset + 3]) << 16 | Int(buffer[offset + 4]) << 24
            guard len >= 0, len <= Self.maxMessage, type == UInt8(ascii: "A") || type == UInt8(ascii: "F") else {
                // Bozuk veri: bağlantıyı yeniden kur.
                buffer.removeAll()
                connection?.cancel()
                return
            }
            guard buffer.endIndex - offset - 5 >= len else { break }
            let start = offset + 5
            let payload = buffer.subdata(in: start..<(start + len))
            offset = start + len
            if type == UInt8(ascii: "A") { handleAudio(payload) } else { handleFrame(payload) }
        }
        if offset > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<offset)
        }
    }

    private func handleAudio(_ data: Data) {
        let count = data.count / 2
        guard count > 0 else { return }
        var samples = [Int16](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            for i in 0..<count {
                samples[i] = Int16(bitPattern: UInt16(b[2 * i]) | (UInt16(b[2 * i + 1]) << 8))
            }
        }
        onAudio?(samples)
    }

    private func handleFrame(_ data: Data) {
        guard data.count > 5 else { return }
        let w = Int(data[data.startIndex]) | Int(data[data.startIndex + 1]) << 8
        let h = Int(data[data.startIndex + 2]) | Int(data[data.startIndex + 3]) << 8
        let o = CGImagePropertyOrientation(rawValue: UInt32(data[data.startIndex + 4])) ?? .up
        guard w > 0, h > 0, data.count - 5 >= w * h else { return }
        let pixels = data.subdata(in: (data.startIndex + 5)..<(data.startIndex + 5 + w * h))
        onFrame?(ScreenFrame(width: w, height: h, orientation: o, pixels: pixels, time: Date()))
    }
}
