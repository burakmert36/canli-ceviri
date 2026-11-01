import Foundation
import Network

/// Yayın uzantısından gelen 16 kHz mono Int16 sesi yalnızca 127.0.0.1 üzerinden dinler.
final class AudioReceiver {
    static let port: UInt16 = 47321

    /// Ses örnekleri (alıcı kuyruğunda çağrılır).
    var onAudio: (([Int16]) -> Void)?
    /// Uzantı bağlandı / koptu (alıcı kuyruğunda çağrılır).
    var onConnectionChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "canliceviri.receiver")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var leftover: UInt8?

    /// Dinlemeyi başlatır (zaten dinliyorsa bir şey yapmaz).
    func ensureListening() {
        queue.async { self.startListener() }
    }

    private func startListener() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
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
        leftover = nil
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.onConnectionChange?(true)
            case .failed, .cancelled:
                if let c = conn, self.connection === c {
                    self.connection = nil
                    self.onConnectionChange?(false)
                }
            default: break
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty, self.connection === conn {
                self.handle(data)
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(on: conn)
        }
    }

    private func handle(_ data: Data) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count + 1)
        if let l = leftover { bytes.append(l); leftover = nil }
        bytes.append(contentsOf: data)
        if bytes.count % 2 == 1 { leftover = bytes.removeLast() }
        let count = bytes.count / 2
        guard count > 0 else { return }
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = Int16(bitPattern: UInt16(bytes[2 * i]) | (UInt16(bytes[2 * i + 1]) << 8))
        }
        onAudio?(samples)
    }

    /// Uzantıya "yayını kapat" komutu gönderir.
    func requestBroadcastStop() {
        queue.async {
            guard let c = self.connection else { return }
            c.send(content: Data("S".utf8), completion: .contentProcessed { _ in })
        }
    }

    var isConnected: Bool {
        queue.sync { connection != nil }
    }
}
