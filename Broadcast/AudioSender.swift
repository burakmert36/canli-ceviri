import Foundation
import Network
import CoreMedia
import CoreVideo
import AudioToolbox
import Accelerate
import ReplayKit

/// Yakalanan sesi (ve istenirse küçültülmüş gri ekran görüntüsünü) ana uygulamaya
/// TCP (yalnızca 127.0.0.1) ile akıtır.
///
/// Mesaj biçimi: [tür: 1 bayt]['uzunluk: 4 bayt LE][veri]
///   'A' → 16 kHz mono Int16 LE ses
///   'F' → [genişlik: UInt16 LE][yükseklik: UInt16 LE][yön: UInt8][gri pikseller]
/// Uygulamadan gelen tek baytlık komutlar: 'S' yayını kapat, 'V' sık görüntü, 'W' seyrek görüntü, 'v' görüntüyü kes,
/// 'M' sesi gönder, 'm' sesi gönderme (altyazı okunurken ses gereksiz: pil), 'K' uygulama nabzı.
/// Uzantı da saniyede bir 'H' nabız mesajı yollar. Uygulamadan 4,5 sn hiçbir şey gelmezse bağlantı ölü sayılır
/// ve yeniden kurulur (uygulama askıya alınıp geri döndüğünde takılı kalmamak için).
final class AudioSender {
    static let port: UInt16 = 47321
    static let maxFrameSide = 1300
    /// Gönderilmeyi bekleyen veri bu sınırı aşarsa yeni ses/görüntü atlanır.
    /// Uzantının bellek sınırı (~50 MB) aşılıp sistemce kapatılmasını önler.
    static let maxPendingBytes = 2 * 1024 * 1024

    var onFinish: ((String) -> Void)?

    let port: UInt16
    init(port: UInt16 = AudioSender.port) {
        self.port = port
    }

    /// Kuyrukta bekleyen gönderim miktarı (yalnızca `queue` üzerinde).
    private var pendingBytes = 0
    /// Atlanan mesaj sayısı (tanı için).
    private(set) var droppedMessages = 0
    /// Uygulamadan son bayt (komut ya da nabız) geldiği an (yalnızca `queue` üzerinde).
    private var lastFromAppAt = Date()
    /// Kaç kez yeniden bağlanıldı (tanı için).
    private(set) var reconnects = 0
    static let staleAfter: TimeInterval = 4.5
    /// Bağlantı kurma denemesinin başladığı an (takılı kalan denemeyi kesmek için).
    private var connectStartedAt = Date()
    private let audioLock = NSLock()
    private var audioEnabled = true

    private let queue = DispatchQueue(label: "canliceviri.sender", autoreleaseFrequency: .workItem)
    private var connection: NWConnection?
    private var ready = false
    private var stopped = false
    private var everConnected = false
    private var startedAt = Date()
    private var lastAliveAt = Date()
    private let converter = PCMConverter(outRate: 16000)
    private var watchdog: DispatchSourceTimer?

    // Görüntü durumu (ReplayKit iş parçacığı ile kuyruk arasında paylaşılır)
    private let videoLock = NSLock()
    private var videoEnabled = false
    private var framePending = false
    private var lastFrameAt = Date.distantPast
    private var frameInterval: TimeInterval = 0.4

    func start() {
        queue.async {
            self.startedAt = Date()
            self.lastAliveAt = Date()
            self.connect()
            self.startWatchdog()
        }
    }

    /// Uzantı nabzı: uygulama bağlantının canlı olduğunu ve uzantının durumunu görür.
    private func sendHeartbeat() {
        guard ready, let conn = connection else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let info = "v=\(version);up=\(Int(Date().timeIntervalSince(startedAt)));rc=\(reconnects);drop=\(droppedMessages)"
        send(Self.message(type: UInt8(ascii: "H"), payload: Data(info.utf8)), on: conn) {}
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.watchdog?.cancel()
            self.watchdog = nil
            self.connection?.cancel()
            self.connection = nil
            self.ready = false
        }
    }

    /// ReplayKit'in kendi iş parçacığında çağrılır (seri).
    func process(_ sampleBuffer: CMSampleBuffer) {
        audioLock.lock(); let on = audioEnabled; audioLock.unlock()
        guard on else { return }
        guard let pcm = converter.convert(sampleBuffer), !pcm.isEmpty else { return }
        let message = Self.message(type: UInt8(ascii: "A"), payload: pcm)
        queue.async {
            guard self.ready, let conn = self.connection else { return }
            self.send(message, on: conn) {}
        }
    }

    /// Geri basınçlı gönderim: alıcı yetişemiyorsa bellek şişmesin diye mesaj atlanır.
    /// `queue` üzerinde çağrılır; `done` her durumda (gönderildi ya da atlandı) bir kez çağrılır.
    private func send(_ message: Data, on conn: NWConnection, done: @escaping () -> Void) {
        if pendingBytes + message.count > Self.maxPendingBytes {
            droppedMessages += 1
            done()
            return
        }
        pendingBytes += message.count
        let size = message.count
        conn.send(content: message, completion: .contentProcessed { [weak self] _ in
            // NWConnection tamamlama bloklarını bağlantının kuyruğunda (queue) çağırır.
            if let self = self { self.pendingBytes = max(0, self.pendingBytes - size) }
            done()
        })
    }

    private func setAudio(_ on: Bool) {
        audioLock.lock(); audioEnabled = on; audioLock.unlock()
    }

    /// Ekran karesi: yalnızca uygulama istediyse, saniyede ~2,5 kez, önceki gönderim bittiyse.
    func processVideo(_ sampleBuffer: CMSampleBuffer) {
        videoLock.lock()
        let wanted = videoEnabled && !framePending && Date().timeIntervalSince(lastFrameAt) >= frameInterval
        if wanted { framePending = true; lastFrameAt = Date() }
        videoLock.unlock()
        guard wanted else { return }

        guard let payload = Self.grayFrame(sampleBuffer) else {
            videoLock.lock(); framePending = false; videoLock.unlock()
            return
        }
        let message = Self.message(type: UInt8(ascii: "F"), payload: payload)
        queue.async {
            guard self.ready, let conn = self.connection else {
                self.videoLock.lock(); self.framePending = false; self.videoLock.unlock()
                return
            }
            self.send(message, on: conn) { [weak self] in
                guard let self = self else { return }
                self.videoLock.lock(); self.framePending = false; self.videoLock.unlock()
            }
        }
    }

    private func setVideo(_ on: Bool, interval: TimeInterval = 0.4) {
        videoLock.lock()
        videoEnabled = on
        frameInterval = interval
        if !on { framePending = false }
        videoLock.unlock()
    }

    static func message(type: UInt8, payload: Data) -> Data {
        var d = Data(capacity: payload.count + 5)
        d.append(type)
        var len = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }

    /// Ekran karesinin parlaklık (Y) kanalını en uzun kenarı ~1280 olacak şekilde küçültür.
    static func grayFrame(_ sb: CMSampleBuffer) -> Data? {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let planar = CVPixelBufferIsPlanar(pb)
        let format = CVPixelBufferGetPixelFormatType(pb)
        let w: Int, h: Int, bpr: Int
        let base: UnsafeMutableRawPointer
        if planar {
            guard let b = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
            base = b
            w = CVPixelBufferGetWidthOfPlane(pb, 0)
            h = CVPixelBufferGetHeightOfPlane(pb, 0)
            bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        } else if format == kCVPixelFormatType_32BGRA {
            guard let b = CVPixelBufferGetBaseAddress(pb) else { return nil }
            base = b
            w = CVPixelBufferGetWidth(pb)
            h = CVPixelBufferGetHeight(pb)
            bpr = CVPixelBufferGetBytesPerRow(pb)
        } else {
            return nil
        }
        guard w > 8, h > 8 else { return nil }

        // Uzun kenar ~1300-2600 piksel arasında kalacak tam sayı küçültme (altyazı yazısı net kalsın).
        let f = max(1, max(w, h) / maxFrameSide)
        let ow = w / f, oh = h / f
        guard ow <= Int(UInt16.max), oh <= Int(UInt16.max) else { return nil }

        var orientation: UInt8 = 1
        if let n = CMGetAttachment(sb, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
            orientation = UInt8(truncatingIfNeeded: n.uint32Value)
        }

        var out = Data(count: 5 + ow * oh)
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let o = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            o[0] = UInt8(ow & 0xff); o[1] = UInt8(ow >> 8)
            o[2] = UInt8(oh & 0xff); o[3] = UInt8(oh >> 8)
            o[4] = orientation
            let px = o + 5
            let src = base.assumingMemoryBound(to: UInt8.self)
            if planar {
                // Parlaklık düzlemini donanım hızlandırmalı (Accelerate) küçült: daha az işlemci, daha az ısınma.
                if f == 1 {
                    for y in 0..<oh { memcpy(px + y * ow, src + y * bpr, ow) }
                    return
                }
                var s = vImage_Buffer(data: base, height: vImagePixelCount(oh * f), width: vImagePixelCount(ow * f), rowBytes: bpr)
                var d = vImage_Buffer(data: UnsafeMutableRawPointer(px), height: vImagePixelCount(oh), width: vImagePixelCount(ow), rowBytes: ow)
                if vImageScale_Planar8(&s, &d, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError { return }
            }
            let area = f * f
            for y in 0..<oh {
                for x in 0..<ow {
                    var sum = 0
                    for dy in 0..<f {
                        let row = src + (y * f + dy) * bpr
                        for dx in 0..<f {
                            let sx = x * f + dx
                            if planar {
                                sum += Int(row[sx])
                            } else {
                                let p = row + sx * 4  // B G R A
                                sum += (Int(p[0]) * 29 + Int(p[1]) * 150 + Int(p[2]) * 77) >> 8
                            }
                        }
                    }
                    px[y * ow + x] = UInt8(sum / area)
                }
            }
        }
        return out
    }

    // MARK: - Bağlantı

    private func connect() {
        guard !stopped, let port = NWEndpoint.Port(rawValue: self.port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: port, using: .tcp)
        connection = conn
        pendingBytes = 0
        lastFromAppAt = Date()
        connectStartedAt = Date()
        // Yeni bağlantıda varsayılanlara dön; uygulama bağlanınca güncel isteklerini yeniden bildirir.
        setAudio(true)
        setVideo(false)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.ready = true
                self.everConnected = true
                self.lastAliveAt = Date()
                self.lastFromAppAt = Date()
                self.receive(on: conn)
                self.sendHeartbeat()
            case .waiting:
                // Örn. uygulama henüz dinlemiyor (bağlantı reddedildi) → kapatıp yeniden dene.
                conn.cancel()
            case .failed, .cancelled:
                if self.connection === conn {
                    self.ready = false
                    self.connection = nil
                    if !self.stopped {
                        self.reconnects += 1
                        self.queue.asyncAfter(deadline: .now() + 0.5) { self.connect() }
                    }
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.lastFromAppAt = Date()
                for byte in data {
                    switch byte {
                    case UInt8(ascii: "S"):
                        self.finish("Canlı çeviri durduruldu.")
                        return
                    case UInt8(ascii: "V"): self.setVideo(true, interval: 0.3)
                    case UInt8(ascii: "W"): self.setVideo(true, interval: 1.0)
                    case UInt8(ascii: "v"): self.setVideo(false)
                    case UInt8(ascii: "M"): self.setAudio(true)
                    case UInt8(ascii: "m"): self.setAudio(false)
                    default: break
                    }
                }
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(on: conn)
        }
    }

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self = self, !self.stopped else { return }
            let now = Date()
            if self.ready {
                if now.timeIntervalSince(self.lastFromAppAt) > Self.staleAfter {
                    // Uygulama cevap vermiyor (ör. askıdan döndü, eski bağlantı ölü): yeniden bağlan.
                    self.ready = false
                    self.connection?.cancel()
                    return
                }
                self.lastAliveAt = now
                self.sendHeartbeat()
                return
            }
            // Bağlanma denemesi 3 sn'den uzun sürdüyse kes ve yeniden dene.
            if let c = self.connection, now.timeIntervalSince(self.connectStartedAt) > 3 {
                c.cancel()
            }
            if !self.everConnected && now.timeIntervalSince(self.startedAt) > 90 {
                self.finish("Önce Canlı Çeviri uygulamasını açıp Başlat'a dokunun.")
            } else if self.everConnected && now.timeIntervalSince(self.lastAliveAt) > 30 {
                self.finish("Canlı Çeviri uygulaması kapandı.")
            }
        }
        t.resume()
        watchdog = t
    }

    private func finish(_ message: String) {
        guard !stopped else { return }
        stopped = true
        watchdog?.cancel()
        watchdog = nil
        connection?.cancel()
        connection = nil
        ready = false
        DispatchQueue.main.async { self.onFinish?(message) }
    }
}

// MARK: - Ses dönüştürücü

/// ReplayKit'ten gelen her türlü doğrusal PCM'i (16/32 bit, float/int, büyük/küçük endian,
/// iç içe/ayrık kanal) 16 kHz mono Int16 little-endian veriye çevirir.
final class PCMConverter {
    let outRate: Double
    private var pos: Double = 0          // mevcut tamponun başına göre okuma konumu (>= -1)
    private var prev: Float = 0          // önceki tamponun son örneği
    private var filter = Biquad()
    private var filterRate: Double = 0
    private var mono: [Float] = []

    init(outRate: Double) { self.outRate = outRate }

    /// Bozuk örnekler (NaN, sonsuz, aşırı büyük) filtreyi kalıcı olarak bozmasın.
    @inline(__always) static func sanitize(_ v: Float) -> Float {
        v.isFinite ? max(-4, min(4, v)) : 0
    }

    func convert(_ sb: CMSampleBuffer) -> Data? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return nil }

        var needed = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard status == noErr, needed > 0 else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { raw.deallocate() }
        let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: ablPtr, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr else { return nil }
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        guard abl.count > 0 else { return nil }

        let flags = asbd.mFormatFlags
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        let isBig = (flags & kAudioFormatFlagIsBigEndian) != 0
        let nonInterleaved = (flags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytes = Int(asbd.mBitsPerChannel) / 8
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        guard bytes == 2 || bytes == 4 else { return nil }

        @inline(__always) func sample(_ p: UnsafeMutableRawPointer, _ offset: Int) -> Float {
            if bytes == 2 {
                var u = p.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                if isBig { u = u.byteSwapped }
                return Float(Int16(bitPattern: u)) / 32768.0
            }
            var u = p.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            if isBig { u = u.byteSwapped }
            if isFloat { return Float(bitPattern: u) }
            return Float(Int32(bitPattern: u)) / 2147483648.0
        }

        mono.removeAll(keepingCapacity: true)
        if nonInterleaved {
            let n = min(frames, Int(abl[0].mDataByteSize) / bytes)
            let chCount = min(channels, abl.count)
            for i in 0..<n {
                var acc: Float = 0
                var used = 0
                for c in 0..<chCount {
                    guard let d = abl[c].mData, Int(abl[c].mDataByteSize) >= (i + 1) * bytes else { continue }
                    acc += sample(d, i * bytes)
                    used += 1
                }
                mono.append(Self.sanitize(used > 0 ? acc / Float(used) : 0))
            }
        } else {
            guard let d = abl[0].mData else { return nil }
            let frameBytes = bytes * channels
            let n = min(frames, Int(abl[0].mDataByteSize) / frameBytes)
            for i in 0..<n {
                var acc: Float = 0
                for c in 0..<channels { acc += sample(d, i * frameBytes + c * bytes) }
                mono.append(Self.sanitize(acc / Float(channels)))
            }
        }
        let n = mono.count
        guard n > 0 else { return nil }

        // Örtüşmeyi (aliasing) azaltmak için alçak geçiren filtre, sonra doğrusal yeniden örnekleme.
        let inRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000
        if inRate != filterRate {
            filter = Biquad.lowpass(sampleRate: inRate, cutoff: min(7000, inRate * 0.45))
            filterRate = inRate
            pos = 0
            prev = 0
        }
        for i in 0..<n { mono[i] = filter.process(mono[i]) }
        if !prev.isFinite { prev = 0 }

        let step = inRate / outRate
        var out = Data(capacity: Int(Double(n) / step + 4) * 2)
        while pos < Double(n - 1) {
            let fl = pos.rounded(.down)
            let i = Int(fl)
            let frac = Float(pos - fl)
            let a = i < 0 ? prev : mono[i]
            let b = mono[i + 1]
            var v = a + (b - a) * frac
            v = v.isFinite ? max(-1, min(1, v)) : 0
            var s = Int16(v * 32767).littleEndian
            withUnsafeBytes(of: &s) { out.append(contentsOf: $0) }
            pos += step
        }
        pos -= Double(n)
        prev = mono[n - 1]
        return out
    }
}

/// RBJ alçak geçiren biquad filtre.
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0

    static func lowpass(sampleRate: Double, cutoff: Double, q: Double = 0.7071) -> Biquad {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        var f = Biquad()
        f.b0 = Float((1 - cosw) / 2 / a0)
        f.b1 = Float((1 - cosw) / a0)
        f.b2 = Float((1 - cosw) / 2 / a0)
        f.a1 = Float(-2 * cosw / a0)
        f.a2 = Float((1 - alpha) / a0)
        return f
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        if !y.isFinite || !z1.isFinite || !z2.isFinite {
            // Filtre durumu bozulduysa sıfırla (aksi hâlde ses kalıcı olarak susar).
            z1 = 0; z2 = 0
            return 0
        }
        return y
    }
}
