import Darwin
import Foundation
@testable import SwiftorrentCore
import Testing

/// A uTP-only peer on 127.0.0.1: a UDP socket driving the responder side of
/// `UTPConnectionCore`. Nothing listens on TCP at its port, so a client has to
/// fall back to uTP to reach it. It answers the BitTorrent handshake with its own.
private final class LoopbackUTPPeer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let infoHash: Data
    private let lock = NSLock()
    private var received = Data()
    private var stopped = false

    init(infoHash: Data) throws {
        self.infoHash = infoHash
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        fd = sock
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, length) }
        }
        guard sock >= 0, bound == 0 else { throw PeerWireError.connectionFailed }
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(sock, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        Thread.detachNewThread { [self] in run() }
    }

    var receivedBytes: Data {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private func run() {
        var core: UTPConnectionCore?
        var remote = sockaddr_in()
        var replied = false
        var buffer = [UInt8](repeating: 0, count: 65536)

        func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }
        func transmit(_ packets: [UTPPacket]) {
            for packet in packets {
                let bytes = [UInt8](packet.encoded())
                withUnsafePointer(to: &remote) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        while true {
            lock.lock(); let done = stopped; lock.unlock()
            if done { break }

            var remoteLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &remoteLength)
                }
            }
            if count > 0, let packet = UTPPacket(Data(buffer[0..<count])) {
                if core == nil, packet.kind == .syn {
                    let responder = UTPConnectionCore(accepting: packet, initialSequence: 900)
                    core = responder
                    transmit(responder.acceptReply(now: now()))
                } else if let core {
                    transmit(core.receive(packet, now: now()))
                    let result = core.read(maxBytes: 65536, now: now())
                    transmit(result.packets)
                    lock.lock(); received.append(result.data); let total = received.count; lock.unlock()
                    if total >= 68, !replied {
                        replied = true
                        var reply = Data([19])
                        reply.append(Data("BitTorrent protocol".utf8))
                        reply.append(Data(repeating: 0, count: 8))
                        reply.append(infoHash)
                        reply.append(Data(repeating: 7, count: 20))
                        transmit(core.write(reply, now: now()))
                    }
                }
            } else if let core {
                transmit(core.tick(now: now()))
            }
        }
        close(fd)
    }
}

@Suite struct UTPTransportTests {
    @Test func clientFallsBackToUTPWhenTCPIsUnreachable() async throws {
        let infoHash = Data((0..<20).map { UInt8($0) })
        let peer = try LoopbackUTPPeer(infoHash: infoHash)
        defer { peer.stop() }

        let client = PeerWireClient(
            endpoint: PeerEndpoint(host: "127.0.0.1", port: peer.port),
            infoHash: infoHash,
            peerID: Data(repeating: 1, count: 20),
            connectTimeout: 3,
            ioTimeout: 3,
            encryptionPolicy: .plaintextOnly
        )
        try await client.connect()
        await client.close()

        let received = peer.receivedBytes
        #expect(received.count >= 68)
        #expect(received.prefix(20) == Data([19]) + Data("BitTorrent protocol".utf8))
        #expect(Data(received[28..<48]) == infoHash)
    }

    /// A cancellation can close the transport before `receive` registers its
    /// waiter; the call must then fail at once instead of parking until a timeout.
    @Test func receiveAfterCloseFailsPromptly() async throws {
        let peer = try LoopbackUTPPeer(infoHash: Data(repeating: 0, count: 20))
        defer { peer.stop() }
        let transport = try UTPPeerTransport(endpoint: PeerEndpoint(host: "127.0.0.1", port: peer.port))
        try await transport.open()
        transport.close()

        let failedPromptly = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { _ = try await transport.receive() } catch { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(failedPromptly)
    }
}
