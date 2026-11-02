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

/// Bağlantı olaylarının kısa günlüğü (Ayarlar › Bağlantı tanısı). Sorun olduğunda nerede koptuğunu gösterir.
final class ConnectionLog {
    static let shared = ConnectionLog()
    private let lock = NSLock()
    private var items: [String] = []
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func add(_ s: String) {
        let line = Self.fmt.string(from: Date()) + "  " + s
        lock.lock()
        items.append(line)
        if items.count > 120 { items.removeFirst(items.count - 120) }
        lock.unlock()
    }

    var entries: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Yayın uzantısından gelen ses ve görüntüyü yalnızca 127.0.0.1 üzerinden dinler.
/// Mesaj biçimi: [tür 1 bayt][uzunluk 4 bayt LE][veri] — 'A' ses, 'F' ekran karesi, 'H' uzantı nabzı (saniyede bir).
/// Uzantıya giden tek baytlık komutlar: 'S' yayını kapat, 'V'/'W'/'v' görüntü sık/seyrek/kapalı, 'M'/'m' ses açık/kapalı,
/// 'K' uygulama nabzı (saniyede bir).
///
/// Kopukluklara karşı:
/// - iOS, askıya alınan uygulamanın dinleme soketini sessizce geri alabilir (Apple TN2277). Bu yüzden dinleyici
///   `restartListener` ile yeniden açılabilir (uygulama öne gelince ve yayın beklenirken).
/// - İki taraf saniyede bir nabız gönderir; 3,5 sn ses gelmeyen bağlantı ölü sayılıp kapatılır, uzantı yeniden bağlanır.
final class AudioReceiver {
    static let port: UInt16 = 47321
    static let maxMessage = 16 * 1024 * 1024
    /// Bu kadar süre uzantıdan hiçbir şey gelmezse bağlantı ölü sayılır.
    static let staleAfter: TimeInterval = 3.5

    let port: UInt16
    let log: ConnectionLog

    init(port: UInt16 = AudioReceiver.port, log: ConnectionLog = .shared) {
        self.port = port
        self.log = log
    }

    /// Ses örnekleri (alıcı kuyruğunda çağrılır).
    var onAudio: (([Int16]) -> Void)?
    /// Ekran karesi (alıcı kuyruğunda çağrılır).
    var onFrame: ((ScreenFrame) -> Void)?
    /// Uzantı bağlandı / koptu (alıcı kuyruğunda çağrılır).
    var onConnectionChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "canliceviri.receiver", autoreleaseFrequency: .workItem)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var connectionReady = false
    private var buffer = Data()
    private var videoMode: VideoMode = .off
    private var audioEnabled = true
    private var lastMessageAt = Date.distantPast
    private var timer: DispatchSourceTimer?
    private var closed = false
    private var peer: String?
    private let stateLock = NSLock()
    private var _isConnected = false

    /// Uzantı şu an bağlı mı? (her iş parçacığından okunabilir)
    var isConnected: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _isConnected }
    /// Uzantının son bildirdiği bilgi (sürüm, çalışma süresi, yeniden bağlanma sayısı).
    var peerInfo: String? { stateLock.lock(); defer { stateLock.unlock() }; return peer }

    /// Uzantıdan istenen ekran görüntüsü sıklığı.
    enum VideoMode {
        case off, fast, slow
        var command: String {
            switch self {
            case .off: return "v"
            case .fast: return "V"   // ~3 kare/sn (altyazı akarken)
            case .slow: return "W"   // ~1 kare/sn (altyazı yokken / pil tasarrufunda)
            }
        }
    }

    /// Dinlemeyi başlatır (zaten dinliyorsa bir şey yapmaz).
    func ensureListening() {
        queue.async {
            self.closed = false
            self.startListener()
            self.startTimer()
        }
    }

    /// Dinleyiciyi kapatıp yeniden açar. Açık bağlantıya dokunmaz.
    /// iOS askıya alınan uygulamanın dinleme soketini geri alabildiği için uygulama öne gelince ve
    /// yayın beklenirken çağrılır.
    func restartListener(reason: String) {
        queue.async {
            guard !self.closed else { return }
            self.log.add("dinleyici yenileniyor (\(reason))")
            if let old = self.listener {
                self.listener = nil
                old.cancel()
            }
            self.startListener()
            self.startTimer()
        }
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
            self.closed = true
            self.timer?.cancel()
            self.timer = nil
            self.connection?.cancel()
            self.connection = nil
            self.setConnected(false)
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

    private func setConnected(_ c: Bool) {
        stateLock.lock(); _isConnected = c; if !c { peer = nil }; stateLock.unlock()
    }

    private func sendCommand(_ c: String) {
        guard let conn = connection, connectionReady else { return }
        conn.send(content: Data(c.utf8), completion: .contentProcessed { _ in })
    }

    /// Saniyede bir: uzantıya nabız gönder, sessiz kalan (ölü) bağlantıyı kapat.
    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.heartbeat() }
        t.resume()
        timer = t
    }

    private func heartbeat() {
        guard let conn = connection, connectionReady else { return }
        if Date().timeIntervalSince(lastMessageAt) > Self.staleAfter {
            log.add("uzantıdan \(Int(Self.staleAfter)) sn ses yok → bağlantı kapatıldı (uzantı yeniden bağlanacak)")
            conn.cancel()
            return
        }
        sendCommand("K")
    }

    private func startListener() {
        guard !closed, listener == nil, let port = NWEndpoint.Port(rawValue: self.port) else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params, on: port)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.log.add("dinleyici hazır (port \(self.port))")
                case .waiting(let e):
                    // Örn. port henüz bırakılmadı: kapatıp yeniden dene.
                    self.log.add("dinleyici bekliyor: \(e)")
                    if self.listener === l { self.listener = nil; l?.cancel(); self.retryListener() }
                case .failed(let e):
                    self.log.add("dinleyici hata: \(e)")
                    if self.listener === l { self.listener = nil; self.retryListener() }
                case .cancelled:
                    if self.listener === l { self.listener = nil; self.retryListener() }
                default: break
                }
            }
            listener = l
            l.start(queue: queue)
        } catch {
            log.add("dinleyici açılamadı: \(error)")
            retryListener()
        }
    }

    private func retryListener() {
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startListener() }
    }

    private func accept(_ conn: NWConnection) {
        if let old = connection {
            log.add("yeni uzantı bağlantısı eskisinin yerini aldı")
            old.cancel()
        }
        connection = conn
        connectionReady = false
        buffer.removeAll()
        lastMessageAt = Date()
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let c = conn, self.connection === c else { return }
            switch state {
            case .ready:
                self.connectionReady = true
                self.lastMessageAt = Date()
                self.setConnected(true)
                self.log.add("uzantı bağlandı")
                // Yeni bağlanan uzantıya güncel istekleri bildir.
                if self.videoMode != .off { self.sendCommand(self.videoMode.command) }
                if !self.audioEnabled { self.sendCommand("m") }
                self.onConnectionChange?(true)
            case .failed, .cancelled:
                let wasReady = self.connectionReady
                self.connection = nil
                self.connectionReady = false
                self.buffer.removeAll()
                self.setConnected(false)
                if wasReady {
                    self.log.add("uzantı bağlantısı kapandı")
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
                self.lastMessageAt = Date()
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
            let known = type == UInt8(ascii: "A") || type == UInt8(ascii: "F") || type == UInt8(ascii: "H")
            guard len >= 0, len <= Self.maxMessage, known else {
                // Bozuk veri: bağlantıyı yeniden kur.
                log.add("bozuk veri (tür \(type), uzunluk \(len)) → bağlantı yenileniyor")
                buffer.removeAll()
                connection?.cancel()
                return
            }
            guard buffer.endIndex - offset - 5 >= len else { break }
            let start = offset + 5
            let payload = buffer.subdata(in: start..<(start + len))
            offset = start + len
            switch type {
            case UInt8(ascii: "A"): handleAudio(payload)
            case UInt8(ascii: "F"): handleFrame(payload)
            default: handleHello(payload)
            }
        }
        if offset > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<offset)
        }
    }

    /// Uzantı nabzı: "v=3.4;up=12;rc=0;drop=0" gibi kısa bilgi.
    private func handleHello(_ data: Data) {
        let info = String(decoding: data.prefix(200), as: UTF8.self)
        stateLock.lock()
        let first = peer == nil
        peer = info
        stateLock.unlock()
        if first { log.add("uzantı bilgisi: \(info)") }
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
        // Geçersiz yön değeri (bozuk veri) Vision'a gitmesin: yalnızca 1–8 geçerlidir.
        let rawO = UInt32(data[data.startIndex + 4])
        let o = (1...8).contains(rawO) ? (CGImagePropertyOrientation(rawValue: rawO) ?? .up) : .up
        guard w > 0, h > 0, data.count - 5 >= w * h else { return }
        let pixels = data.subdata(in: (data.startIndex + 5)..<(data.startIndex + 5 + w * h))
        onFrame?(ScreenFrame(width: w, height: h, orientation: o, pixels: pixels, time: Date()))
    }
}
