import XCTest
import UIKit
import CoreMedia
import CoreVideo
import AudioToolbox
import Darwin
@testable import CanliCeviri

// MARK: - Bekleme

/// Ana iş parçacığının çalışma döngüsünü döndürerek koşulu bekler (Engine ana kuyrukta çalışır).
@discardableResult
func waitUntil(_ timeout: TimeInterval, poll: TimeInterval = 0.02, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(poll))
    }
    return condition()
}

/// Belirli bir süre ana döngüyü çalıştırır.
func spin(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

/// Eşzamanlı görevlerden sonuç taşımak için kilitli kutu.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&_value); lock.unlock() }
}

/// Testler arasında çakışmasın diye her alıcıya ayrı bir port.
enum TestPorts {
    private static var next: UInt16 = 47400
    private static let lock = NSLock()
    static func make() -> UInt16 {
        lock.lock(); defer { lock.unlock() }
        next += 1
        return next
    }
}

/// Uygulamanın bellekteki kapladığı alan (MB).
func memoryFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    return Double(info.phys_footprint) / 1_048_576
}

// MARK: - Basit TCP istemcisi (yayın uzantısını taklit eder)

final class TCPClient {
    private(set) var fd: Int32 = -1

    init?(port: UInt16, timeout: TimeInterval = 3) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            guard s >= 0 else { return nil }
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if ok == 0 { fd = s; return }
            Darwin.close(s)
            spin(0.05)
        }
        return nil
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        guard fd >= 0 else { return false }
        var sent = 0
        let total = data.count
        let ok: Bool = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return total == 0 }
            while sent < total {
                let n = Darwin.send(fd, base + sent, total - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
        return ok
    }

    /// Gelen baytları (komutları) belirli süre okur.
    func receive(timeout: TimeInterval) -> Data {
        guard fd >= 0 else { return Data() }
        var out = Data()
        let end = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 256)
        while Date() < end {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, 50)
            if r > 0 {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                out.append(contentsOf: buf[0..<n])
            } else {
                spin(0.01)
            }
        }
        return out
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    deinit { close() }
}

// MARK: - Mesaj oluşturma (uzantının biçimi)

enum Wire {
    static func message(_ type: Character, _ payload: Data) -> Data {
        var d = Data()
        d.append(type.asciiValue!)
        var len = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }

    static func audio(_ samples: [Int16]) -> Data {
        var p = Data(capacity: samples.count * 2)
        for s in samples {
            var v = s.littleEndian
            withUnsafeBytes(of: &v) { p.append(contentsOf: $0) }
        }
        return message("A", p)
    }

    static func frame(width: Int, height: Int, orientation: UInt8, pixels: Data) -> Data {
        var p = Data()
        p.append(UInt8(width & 0xff)); p.append(UInt8(width >> 8))
        p.append(UInt8(height & 0xff)); p.append(UInt8(height >> 8))
        p.append(orientation)
        p.append(pixels)
        return message("F", p)
    }

    static func sine(freq: Double, seconds: Double, rate: Double = 16000, amplitude: Double = 0.5) -> [Int16] {
        let n = Int(seconds * rate)
        return (0..<n).map { i in Int16(sin(2 * .pi * freq * Double(i) / rate) * amplitude * 32767) }
    }
}

// MARK: - Altyazılı sahte ekran görüntüsü

enum FakeScreen {
    /// Siyah zemin üzerinde verilen konumlara beyaz yazılar çizilmiş gri tonlamalı kare.
    /// - Parameter texts: (yazı, sol üst köşe başlangıçlı 0–1 dikey konum)
    static func gray(width: Int, height: Int, texts: [(String, CGFloat)], fontSize: CGFloat = 30,
                     noiseSeed: Int? = nil) -> Data {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: fmt).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let seed = noiseSeed {
                // Videoyu taklit eden hareketli kutular
                var g = SeededRandom(seed: UInt64(seed))
                for _ in 0..<12 {
                    UIColor(white: CGFloat(g.next() % 100) / 300, alpha: 1).setFill()
                    let w = CGFloat(g.next() % UInt64(max(1, width / 3))) + 10
                    let h = CGFloat(g.next() % UInt64(max(1, height / 6))) + 10
                    let x = CGFloat(g.next() % UInt64(max(1, width)))
                    let y = CGFloat(g.next() % UInt64(max(1, height)))
                    ctx.fill(CGRect(x: x, y: y, width: w, height: h))
                }
            }
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            for (t, y) in texts {
                let s = NSAttributedString(string: t, attributes: [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: UIColor.white, .paragraphStyle: p,
                ])
                s.draw(in: CGRect(x: 10, y: y * CGFloat(height), width: CGFloat(width) - 20, height: fontSize * 1.5))
            }
        }
        return grayPixels(img, width: width, height: height)
    }

    static func grayPixels(_ img: UIImage, width: Int, height: Int) -> Data {
        var data = Data(count: width * height)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let cg = img.cgImage else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }

    /// Dikey görüntüyü saat yönünde 90° çevirerek "ham" yatay kare üretir (yön: .left ile dik okunur).
    static func rotateCW(_ pixels: Data, width: Int, height: Int) -> Data {
        // Çıktı: genişlik = height, yükseklik = width
        var out = Data(count: width * height)
        pixels.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let s = src.bindMemory(to: UInt8.self), d = dst.bindMemory(to: UInt8.self)
                let ow = height
                for y in 0..<height {
                    for x in 0..<width {
                        d[x * ow + (height - 1 - y)] = s[y * width + x]
                    }
                }
            }
        }
        return out
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ range: Range<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}

// MARK: - CoreMedia örnekleri (uzantıya giden ses/görüntü)

enum SampleFactory {
    struct AudioFormat {
        var rate: Double
        var channels: Int
        var bits: Int
        var float: Bool
        var bigEndian: Bool
        var nonInterleaved: Bool
    }

    /// Verilen formatta sinüs içeren bir ses CMSampleBuffer'ı oluşturur.
    static func audio(_ f: AudioFormat, frames: Int, freq: Double, amplitude: Double = 0.5,
                      startFrame: Int = 0, overrideValue: Float? = nil) -> CMSampleBuffer? {
        let bytes = f.bits / 8
        var flags: AudioFormatFlags = kAudioFormatFlagIsPacked
        flags |= f.float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger
        if f.bigEndian { flags |= kAudioFormatFlagIsBigEndian }
        if f.nonInterleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        let bytesPerFrame = f.nonInterleaved ? bytes : bytes * f.channels
        var asbd = AudioStreamBasicDescription(
            mSampleRate: f.rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1, mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(f.channels), mBitsPerChannel: UInt32(f.bits), mReserved: 0)
        var fmt: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &fmt) == noErr, let format = fmt else { return nil }

        func encode(_ v: Float) -> [UInt8] {
            if f.bits == 16 {
                var u = UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32767))
                u = f.bigEndian ? u.bigEndian : u.littleEndian
                return withUnsafeBytes(of: u) { Array($0) }
            }
            var u: UInt32 = f.float ? v.bitPattern : UInt32(bitPattern: Int32(Double(max(-1, min(1, v))) * 2147483647))
            u = f.bigEndian ? u.bigEndian : u.littleEndian
            return withUnsafeBytes(of: u) { Array($0) }
        }
        func value(_ i: Int, _ ch: Int) -> Float {
            if let o = overrideValue { return o }
            return Float(sin(2 * .pi * freq * Double(startFrame + i) / f.rate) * amplitude) * (ch == 0 ? 1 : 0.9)
        }

        // Kanallar: ayrık ise ardışık düzlemler; tek blok tampona yazılır.
        var bytesOut = [UInt8]()
        bytesOut.reserveCapacity(frames * bytes * f.channels)
        if f.nonInterleaved {
            for c in 0..<f.channels { for i in 0..<frames { bytesOut += encode(value(i, c)) } }
        } else {
            for i in 0..<frames { for c in 0..<f.channels { bytesOut += encode(value(i, c)) } }
        }

        var block: CMBlockBuffer?
        let total = bytesOut.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: total, flags: 0,
                                                 blockBufferOut: &block) == noErr, let bb = block else { return nil }
        guard CMBlockBufferReplaceDataBytes(with: bytesOut, blockBuffer: bb, offsetIntoDestination: 0,
                                            dataLength: total) == noErr else { return nil }

        var sb: CMSampleBuffer?
        let pts = CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(f.rate))
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb)
        guard status == noErr else { return nil }
        return sb
    }

    /// BGRA ya da 420f görüntüden bir video CMSampleBuffer'ı oluşturur.
    static func video(width: Int, height: Int, gray: Data, biplanar: Bool) -> CMSampleBuffer? {
        var pbOut: CVPixelBuffer?
        let format = biplanar ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &pbOut) == kCVReturnSuccess,
              let pb = pbOut else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        gray.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            let s = src.bindMemory(to: UInt8.self)
            if biplanar {
                let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
                let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                for y in 0..<height { for x in 0..<width { base[y * bpr + x] = s[y * width + x] } }
                if let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
                    memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * CVPixelBufferGetHeightOfPlane(pb, 1))
                }
            } else {
                let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
                let bpr = CVPixelBufferGetBytesPerRow(pb)
                for y in 0..<height {
                    for x in 0..<width {
                        let v = s[y * width + x]
                        let p = base + y * bpr + x * 4
                        p[0] = v; p[1] = v; p[2] = v; p[3] = 255
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        var fmt: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                           formatDescriptionOut: &fmt) == noErr, let vf = fmt else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                       formatDescription: vf, sampleTiming: &timing,
                                                       sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    /// Int16 LE baytlarını örneklere çevirir.
    static func int16s(_ d: Data) -> [Int16] {
        var out = [Int16](repeating: 0, count: d.count / 2)
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            for i in 0..<out.count { out[i] = Int16(bitPattern: UInt16(b[2 * i]) | UInt16(b[2 * i + 1]) << 8) }
        }
        return out
    }

    /// Basit frekans tahmini (sıfır geçişleri).
    static func estimateFrequency(_ s: [Int16], rate: Double) -> Double {
        guard s.count > 2 else { return 0 }
        var crossings = 0
        for i in 1..<s.count where (s[i - 1] < 0) != (s[i] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(s.count) / rate)
    }
}

// MARK: - Sahte ağ (URLProtocol)

final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var body: Data
        var delay: TimeInterval = 0
        var failure: URLError.Code?
    }

    private static let lock = NSLock()
    private static var _handler: ((URLRequest, Data?) -> Reply)?
    private static var _requests: [(URLRequest, Data?)] = []

    static func setHandler(_ h: @escaping (URLRequest, Data?) -> Reply) {
        lock.lock(); _handler = h; _requests = []; lock.unlock()
    }

    static func reset() {
        lock.lock(); _handler = nil; _requests = []; lock.unlock()
    }

    static var requests: [(URLRequest, Data?)] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    static func json(_ obj: Any, status: Int = 200) -> Reply {
        Reply(status: status, body: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data())
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var cancelled = false

    override func startLoading() {
        let body = request.httpBody ?? Self.readStream(request.httpBodyStream)
        Self.lock.lock()
        Self._requests.append((request, body))
        let h = Self._handler
        Self.lock.unlock()
        let reply = h?(request, body) ?? Reply(status: 500, body: Data("no handler".utf8))
        let deliver = { [weak self] in
            guard let self = self, !self.cancelled else { return }
            if let code = reply.failure {
                self.client?.urlProtocol(self, didFailWithError: URLError(code))
                return
            }
            let resp = HTTPURLResponse(url: self.request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: reply.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() { cancelled = true }

    static func readStream(_ s: InputStream?) -> Data? {
        guard let s = s else { return nil }
        s.open(); defer { s.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }

    static func jsonBody(_ d: Data?) -> [String: Any] {
        guard let d = d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
}

/// Sahte ağı etkinleştirir; test bitince gerçek oturuma döner.
enum StubNetwork {
    static func install() {
        HTTP.session = HTTP.makeSession(protocols: [StubURLProtocol.self])
        NetworkMonitor.shared.override = true
        TranslationCache.shared.removeAll()
    }

    static func uninstall() {
        StubURLProtocol.reset()
        HTTP.session = HTTP.makeSession()
        NetworkMonitor.shared.override = nil
        TranslationCache.shared.removeAll()
    }

    /// Google'ın gerçek yanıt biçimi: [[["çeviri","kaynak",...],...],...]
    static func googleReply(_ text: String) -> StubURLProtocol.Reply {
        StubURLProtocol.json([[[text, "src", NSNull(), NSNull(), 10]], NSNull(), "en"])
    }

    /// İstekteki "q" parametresi.
    static func googleQuery(_ r: URLRequest) -> String {
        URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
    }
}
