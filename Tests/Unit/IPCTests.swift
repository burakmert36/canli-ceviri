import XCTest
@testable import CanliCeviri

/// Uygulama ↔ yayın uzantısı yerel bağlantısı: biçim, parçalanma, bozuk veri, kopma/yeniden bağlanma, yük.
final class IPCTests: XCTestCase {
    private var receiver: AudioReceiver!
    private var port: UInt16 = 0
    private let lock = NSLock()
    private var audio: [Int16] = []
    private var frames: [ScreenFrame] = []
    private var connects = 0
    private var disconnects = 0

    override func setUp() {
        super.setUp()
        port = TestPorts.make()
        receiver = AudioReceiver(port: port)
        receiver.onAudio = { [weak self] s in
            guard let self = self else { return }
            self.lock.lock(); self.audio.append(contentsOf: s); self.lock.unlock()
        }
        receiver.onFrame = { [weak self] f in
            guard let self = self else { return }
            self.lock.lock(); self.frames.append(f); self.lock.unlock()
        }
        receiver.onConnectionChange = { [weak self] c in
            guard let self = self else { return }
            self.lock.lock(); if c { self.connects += 1 } else { self.disconnects += 1 }; self.lock.unlock()
        }
        receiver.ensureListening()
        spin(0.3)
    }

    override func tearDown() {
        receiver.shutdown()
        receiver = nil
        super.tearDown()
    }

    private var audioCount: Int { lock.lock(); defer { lock.unlock() }; return audio.count }
    private var frameCount: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    private var connectCount: Int { lock.lock(); defer { lock.unlock() }; return connects }
    private var disconnectCount: Int { lock.lock(); defer { lock.unlock() }; return disconnects }

    private func connect() -> TCPClient {
        guard let c = TCPClient(port: port) else {
            XCTFail("Bağlanılamadı")
            return TCPClient(port: port)!
        }
        return c
    }

    func testAudioMessageDecodesLittleEndianSamples() {
        let c = connect()
        let samples: [Int16] = [0, 1, -1, 32767, -32768, 1234, -4321]
        c.send(Wire.audio(samples))
        XCTAssertTrue(waitUntil(3) { self.audioCount == samples.count })
        lock.lock(); XCTAssertEqual(audio, samples); lock.unlock()
    }

    func testFrameMessageDecodes() {
        let c = connect()
        let w = 64, h = 32
        let px = Data((0..<(w * h)).map { UInt8($0 % 251) })
        c.send(Wire.frame(width: w, height: h, orientation: 6, pixels: px))
        XCTAssertTrue(waitUntil(3) { self.frameCount == 1 })
        lock.lock()
        let f = frames.first
        lock.unlock()
        XCTAssertEqual(f?.width, w)
        XCTAssertEqual(f?.height, h)
        XCTAssertEqual(f?.orientation, .right)
        XCTAssertEqual(f?.pixels, px)
        // .right yönünde 64×32 ham görüntü dik çevrilince 32×64: dikey.
        XCTAssertEqual(f?.isLandscape, false)
    }

    func testByteByByteFragmentation() {
        let c = connect()
        let samples = Wire.sine(freq: 300, seconds: 0.05)
        let msg = Wire.audio(samples) + Wire.frame(width: 10, height: 10, orientation: 1, pixels: Data(repeating: 7, count: 100))
        for b in msg { c.send(Data([b])) }
        XCTAssertTrue(waitUntil(5) { self.audioCount == samples.count && self.frameCount == 1 })
    }

    func testManyMessagesCoalescedInOneWrite() {
        let c = connect()
        var blob = Data()
        for i in 0..<500 { blob.append(Wire.audio([Int16(i), Int16(-i)])) }
        c.send(blob)
        XCTAssertTrue(waitUntil(5) { self.audioCount == 1000 })
        lock.lock(); XCTAssertEqual(audio.suffix(2), [499, -499]); lock.unlock()
    }

    func testGarbageTypeDropsConnectionAndRecovers() {
        let c = connect()
        XCTAssertTrue(waitUntil(3) { self.connectCount >= 1 })
        c.send(Data([0x5A, 1, 0, 0, 0, 9]))   // bilinmeyen tür 'Z'
        XCTAssertTrue(waitUntil(3) { self.disconnectCount >= 1 }, "Bozuk veride bağlantı kapanmalı")
        // Yeni bağlantı sorunsuz çalışmalı.
        let c2 = connect()
        c2.send(Wire.audio([42]))
        XCTAssertTrue(waitUntil(3) { self.audioCount == 1 })
        c.close()
    }

    func testHugeLengthIsRejectedWithoutAllocating() {
        let before = memoryFootprintMB()
        let c = connect()
        c.send(Data([UInt8(ascii: "F"), 0xFF, 0xFF, 0xFF, 0xFF]))  // 4 GB uzunluk iddiası
        c.send(Data(repeating: 1, count: 4096))
        XCTAssertTrue(waitUntil(3) { self.disconnectCount >= 1 })
        XCTAssertEqual(frameCount, 0)
        assertMemoryGrowth(memoryFootprintMB() - before, below: 50, "4 GB uzunluk iddiası")
    }

    func testTruncatedAndInconsistentFramesAreIgnored() {
        let c = connect()
        // Genişlik×yükseklik verideki pikselden fazla
        c.send(Wire.frame(width: 1000, height: 1000, orientation: 1, pixels: Data(repeating: 0, count: 10)))
        // Sıfır boyut
        c.send(Wire.frame(width: 0, height: 10, orientation: 1, pixels: Data()))
        // Çok kısa çerçeve verisi
        c.send(Wire.message("F", Data([1, 2])))
        // Geçersiz yön değeri
        c.send(Wire.frame(width: 4, height: 4, orientation: 200, pixels: Data(repeating: 9, count: 16)))
        // Tek baytlık ses (yarım örnek)
        c.send(Wire.message("A", Data([1])))
        XCTAssertTrue(waitUntil(3) { self.frameCount == 1 })
        lock.lock(); XCTAssertEqual(frames.first?.orientation, .up); lock.unlock()
        XCTAssertEqual(audioCount, 0)
    }

    func testCommandsReachExtension() {
        let c = connect()
        XCTAssertTrue(waitUntil(3) { self.connectCount >= 1 })
        receiver.setVideoMode(.fast)
        receiver.setAudioEnabled(false)
        receiver.setVideoMode(.slow)
        receiver.requestBroadcastStop()
        // 'K' uygulamanın saniyelik nabzıdır; komut sırasına karışabilir.
        let got = String(decoding: c.receive(timeout: 1.5), as: UTF8.self).replacingOccurrences(of: "K", with: "")
        XCTAssertEqual(got, "VmWS")
    }

    func testReconnectResendsCurrentModes() {
        receiver.setVideoMode(.fast)
        receiver.setAudioEnabled(false)
        spin(0.2)
        let c = connect()
        let got = String(decoding: c.receive(timeout: 1.5), as: UTF8.self)
        XCTAssertTrue(got.contains("V"), "Yeni bağlantıya görüntü isteği yeniden gönderilmeli: \(got)")
        XCTAssertTrue(got.contains("m"), "Yeni bağlantıya ses kapalı bilgisi gönderilmeli: \(got)")
    }

    func testNewestConnectionWins() {
        let a = connect()
        XCTAssertTrue(waitUntil(3) { self.connectCount >= 1 })
        let b = connect()
        XCTAssertTrue(waitUntil(3) { self.connectCount >= 2 })
        a.send(Wire.audio([1, 1, 1]))   // eski bağlantının verisi alınmamalı
        b.send(Wire.audio([2]))
        XCTAssertTrue(waitUntil(3) { self.audioCount >= 1 })
        spin(0.3)
        lock.lock(); XCTAssertEqual(audio, [2]); lock.unlock()
    }

    // MARK: Nabız ve ölü bağlantı (v3.4)

    func testSilentConnectionIsDroppedSoExtensionCanReconnect() {
        let c = connect()
        XCTAssertTrue(waitUntil(3) { self.connectCount >= 1 })
        let start = Date()
        // Uzantı hiçbir şey göndermiyor (askıdan dönmüş ölü bağlantı gibi)
        XCTAssertTrue(waitUntil(7) { self.disconnectCount >= 1 }, "Sessiz bağlantı kapatılmalı")
        let took = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(took, 3.0)
        XCTAssertLessThan(took, 6.0)
        XCTAssertFalse(receiver.isConnected)
        c.close()
    }

    func testHeartbeatKeepsConnectionAliveAndReportsPeerInfo() {
        let c = connect()
        c.startHeartbeat()
        spin(7)
        XCTAssertEqual(disconnectCount, 0, "Nabız gelen bağlantı kapatılmamalı")
        XCTAssertTrue(receiver.isConnected)
        XCTAssertEqual(receiver.peerInfo, "v=test;up=1;rc=0;drop=0")
        // Uygulama da saniyede bir 'K' gönderir
        let got = String(decoding: c.receive(timeout: 2.5), as: UTF8.self)
        XCTAssertTrue(got.contains("K"), "Uygulama nabzı gelmedi: \(got)")
        c.close()
    }

    func testListenerRestartKeepsServing() {
        // Askıdan dönüşte dinleyici yenilenir; hızlı ardışık yenilemeler de sorun çıkarmamalı.
        for i in 0..<15 { receiver.restartListener(reason: "test \(i)") }
        spin(1.5)
        guard let c = TCPClient(port: port, timeout: 5) else { XCTFail("Yenilenen dinleyiciye bağlanılamadı"); return }
        c.send(Wire.audio([5, 6]))
        XCTAssertTrue(waitUntil(5) { self.audioCount == 2 })
        c.close()
    }

    func testListenerRestartDoesNotDropActiveConnection() {
        let c = connect()
        c.startHeartbeat()
        XCTAssertTrue(waitUntil(3) { self.connectCount >= 1 })
        receiver.restartListener(reason: "test")
        spin(1)
        c.send(Wire.audio([1, 2, 3]))
        XCTAssertTrue(waitUntil(3) { self.audioCount == 3 })
        XCTAssertEqual(disconnectCount, 0)
        c.close()
    }

    /// Stres: 150 kez bağlan → veri gönder → kop.
    func testRapidConnectDisconnectStress() {
        for i in 0..<150 {
            guard let c = TCPClient(port: port) else { XCTFail("Bağlantı \(i) kurulamadı"); return }
            c.send(Wire.audio([Int16(i)]))
            if i % 3 == 0 { c.send(Data([0x00, 0x01])) }   // yarım mesaj bırakıp kop
            c.close()
        }
        // Alıcı hâlâ çalışıyor mu?
        let c = connect()
        let before = audioCount
        c.send(Wire.audio(Wire.sine(freq: 440, seconds: 0.1)))
        XCTAssertTrue(waitUntil(5) { self.audioCount >= before + 1600 })
    }

    /// Yük: ~10 saniyelik ses + 30 tam boy kare tek seferde.
    func testThroughputStress() {
        let c = connect()
        let chunk = Wire.audio(Wire.sine(freq: 220, seconds: 0.1))
        var blob = Data()
        for _ in 0..<100 { blob.append(chunk) }
        let w = 603, h = 1311   // iPhone 17 ekranının uzantıdaki küçültülmüş boyutu
        let frame = Wire.frame(width: w, height: h, orientation: 1, pixels: Data(repeating: 128, count: w * h))
        for _ in 0..<30 { blob.append(frame) }
        XCTAssertTrue(c.send(blob))
        XCTAssertTrue(waitUntil(15) { self.audioCount == 160_000 && self.frameCount == 30 },
                      "audio=\(audioCount) frames=\(frameCount)")
    }

    /// Rastgele bayt yağmuru: çökmemeli, sonra normal çalışmalı.
    func testFuzzRandomBytes() {
        var g = SeededRandom(seed: 42)
        for round in 0..<40 {
            guard let c = TCPClient(port: port) else { XCTFail("round \(round)"); return }
            var junk = Data(count: g.int(1..<4000))
            junk.withUnsafeMutableBytes { raw in
                for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: g.next()) }
            }
            // Bazen geçerli başlıkla başlayan bozuk veri
            if round % 2 == 0 { junk.insert(contentsOf: [UInt8(ascii: "F"), 0x10, 0, 0, 0], at: 0) }
            c.send(junk)
            c.close()
        }
        let c = connect()
        spin(0.5)
        let before = audioCount
        c.send(Wire.audio([7, 8, 9]))
        XCTAssertTrue(waitUntil(5) { self.audioCount == before + 3 })
    }
}

/// Uzantının gönderici sınıfı ile uygulamanın alıcısı arasında uçtan uca test.
final class SenderReceiverTests: XCTestCase {
    func testAudioAndVideoFlowEndToEnd() {
        let port = TestPorts.make()
        let receiver = AudioReceiver(port: port)
        let lock = NSLock()
        var samples: [Int16] = []
        var frames: [ScreenFrame] = []
        receiver.onAudio = { s in lock.lock(); samples += s; lock.unlock() }
        receiver.onFrame = { f in lock.lock(); frames.append(f); lock.unlock() }
        receiver.ensureListening()
        spin(0.3)
        defer { receiver.shutdown() }

        let sender = AudioSender(port: port)
        var finished: String?
        sender.onFinish = { finished = $0 }
        sender.start()
        defer { sender.stop() }
        spin(1.5)   // bağlan

        // Ses: 48 kHz stereo float → 16 kHz mono
        let fmt = SampleFactory.AudioFormat(rate: 48000, channels: 2, bits: 32, float: true, bigEndian: false, nonInterleaved: false)
        for k in 0..<20 {
            guard let sb = SampleFactory.audio(fmt, frames: 1024, freq: 500, startFrame: k * 1024) else {
                XCTFail("ses örneği oluşturulamadı"); return
            }
            sender.process(sb)
        }
        XCTAssertTrue(waitUntil(5) { lock.lock(); defer { lock.unlock() }; return samples.count > 6000 })
        lock.lock()
        let freq = SampleFactory.estimateFrequency(Array(samples.dropFirst(200)), rate: 16000)
        lock.unlock()
        XCTAssertEqual(freq, 500, accuracy: 25, "Yeniden örneklenen sesin frekansı korunmalı")

        // Görüntü: uygulama istemeden gönderilmemeli
        let w = 1206, h = 2622  // iPhone 17 ekranı
        let gray = Data(repeating: 200, count: w * h)
        guard let vb = SampleFactory.video(width: w, height: h, gray: gray, biplanar: true) else {
            XCTFail("görüntü oluşturulamadı"); return
        }
        sender.processVideo(vb)
        spin(0.5)
        lock.lock(); XCTAssertEqual(frames.count, 0); lock.unlock()

        receiver.setVideoMode(.fast)
        spin(0.4)
        for _ in 0..<6 { sender.processVideo(vb); spin(0.45) }
        XCTAssertTrue(waitUntil(5) { lock.lock(); defer { lock.unlock() }; return frames.count >= 3 })
        lock.lock()
        let f = frames.first
        lock.unlock()
        XCTAssertEqual(f?.width, w / 2)
        XCTAssertEqual(f?.height, h / 2)
        XCTAssertEqual(f?.pixels.first, 200)

        // Ses kapatılınca uzantı ses göndermemeli (pil)
        receiver.setAudioEnabled(false)
        spin(0.4)
        lock.lock(); let countBefore = samples.count; lock.unlock()
        for k in 0..<10 {
            if let sb = SampleFactory.audio(fmt, frames: 1024, freq: 500, startFrame: k * 1024) { sender.process(sb) }
        }
        spin(0.6)
        lock.lock(); XCTAssertEqual(samples.count, countBefore); lock.unlock()

        // Durdurma komutu uzantıyı kapatmalı
        receiver.requestBroadcastStop()
        XCTAssertTrue(waitUntil(3) { finished != nil })
    }

    /// Uygulama yeniden başlarsa (dinleyici kapanıp açılırsa) uzantı kendiliğinden yeniden bağlanmalı.
    func testSenderReconnectsAfterReceiverRestart() {
        let port = TestPorts.make()
        let lock = NSLock()
        var samples = 0
        func makeReceiver() -> AudioReceiver {
            let r = AudioReceiver(port: port)
            r.onAudio = { s in lock.lock(); samples += s.count; lock.unlock() }
            r.ensureListening()
            return r
        }
        var receiver = makeReceiver()
        let sender = AudioSender(port: port)
        sender.start()
        defer { sender.stop() }
        XCTAssertTrue(waitUntil(5) { receiver.isConnected })
        receiver.shutdown()
        spin(1.5)
        receiver = makeReceiver()
        XCTAssertTrue(waitUntil(6) { receiver.isConnected }, "Uzantı yeniden bağlanmadı")
        let fmt = SampleFactory.AudioFormat(rate: 48000, channels: 1, bits: 16, float: false, bigEndian: false, nonInterleaved: false)
        for k in 0..<5 { if let sb = SampleFactory.audio(fmt, frames: 4800, freq: 300, startFrame: k * 4800) { sender.process(sb) } }
        XCTAssertTrue(waitUntil(5) { lock.lock(); defer { lock.unlock() }; return samples > 6000 })
        XCTAssertGreaterThan(sender.reconnects, 0)
        receiver.shutdown()
    }

    /// Bağlantıyı kabul edip hiç cevap vermeyen (askıda kalmış) uygulama: uzantı bunu fark edip yeniden bağlanmalı.
    func testSenderDetectsUnresponsiveApp() {
        let port = TestPorts.make()
        let listenFD = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        listen(listenFD, 8)
        let accepted = Box(0)
        let acceptedFDs = Box<[Int32]>([])
        DispatchQueue(label: "test.accept").async {
            while true {
                let fd = accept(listenFD, nil, nil)
                if fd < 0 { break }
                accepted.mutate { $0 += 1 }
                acceptedFDs.mutate { $0.append(fd) }   // açık tut ama hiç yazma
            }
        }
        let sender = AudioSender(port: port)
        sender.start()
        XCTAssertTrue(waitUntil(12) { accepted.value >= 2 }, "Uzantı cevapsız uygulamayı fark edip yeniden bağlanmalı (kabul: \(accepted.value))")
        sender.stop()
        spin(0.3)
        close(listenFD)
        for fd in acceptedFDs.value { close(fd) }
    }

    func testBGRAFrameConversion() {
        let w = 400, h = 300
        var g = Data(count: w * h)
        for i in 0..<g.count { g[i] = UInt8(i % 256) }
        guard let sb = SampleFactory.video(width: w, height: h, gray: g, biplanar: false),
              let out = AudioSender.grayFrame(sb) else { XCTFail(); return }
        XCTAssertEqual(out.count, 5 + w * h)
        XCTAssertEqual(Int(out[0]) | Int(out[1]) << 8, w)
        XCTAssertEqual(Int(out[2]) | Int(out[3]) << 8, h)
        // BGRA → parlaklık dönüşümü griyi (neredeyse) korumalı
        for i in stride(from: 0, to: w * h, by: 997) {
            XCTAssertEqual(Double(out[5 + i]), Double(g[i]), accuracy: 2)
        }
    }

    /// Uygulama yaşıyor (nabız gönderiyor) ama veriyi okuyamıyor: uzantı belleği şişmemeli, fazlası atlanmalı.
    /// (Uygulama tamamen donarsa nabız da kesilir; o durumu `testSenderDetectsUnresponsiveApp` sınar.)
    func testSenderBackPressureWhenReceiverStalls() {
        let port = TestPorts.make()
        let listenFD = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        listen(listenFD, 4)
        let done = Box(false)
        let fds = Box<[Int32]>([])
        // Kabul et, hiç okuma, yalnızca yarım saniyede bir 'K' nabzı yolla.
        DispatchQueue(label: "test.accept").async {
            while !done.value {
                let fd = accept(listenFD, nil, nil)
                if fd < 0 { break }
                var nosig: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
                fds.mutate { $0.append(fd) }
            }
        }
        DispatchQueue(label: "test.beat").async {
            let k: [UInt8] = [UInt8(ascii: "K")]
            while !done.value {
                for fd in fds.value { _ = Darwin.send(fd, k, 1, 0) }
                usleep(500_000)
            }
        }
        let sender = AudioSender(port: port)
        sender.start()
        defer {
            sender.stop()
            done.value = true
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            spin(0.6)
            for fd in fds.value { close(fd) }
        }
        XCTAssertTrue(waitUntil(5) { !fds.value.isEmpty }, "Uzantı bağlanamadı")
        spin(0.5)
        let before = memoryFootprintMB()
        // 5 dakikalık ses (16 kHz tek kanal: dönüştürme ucuz, test kısa sürer); alıcı hiç okumuyor.
        let fmt = SampleFactory.AudioFormat(rate: 16000, channels: 1, bits: 16, float: false, bigEndian: false, nonInterleaved: false)
        guard let sb = SampleFactory.audio(fmt, frames: 16000, freq: 300) else { XCTFail(); return }
        for _ in 0..<300 { sender.process(sb) }
        spin(2)
        assertMemoryGrowth(memoryFootprintMB() - before, below: 30, "uzantı: alıcı okumazken 5 dk ses")
        XCTAssertGreaterThan(sender.droppedMessages, 0, "Alıcı okumazken fazlası atlanmalı")
    }
}
