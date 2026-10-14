import Foundation
import Network

/// How many peers of a swarm answer on TCP and on uTP. Used by the bench's
/// `--utp-probe` to decide whether an outbound uTP transport is worth having.
public struct UTPProbeResult: Sendable {
    public var peers = 0
    public var tcpReachable = 0
    public var utpReachable = 0
    /// Peers that refused TCP but answered a uTP SYN: the ones uTP would add.
    public var utpOnly = 0
}

public enum UTPProbe {
    private static let timeout: TimeInterval = 5
    private static let concurrency = 50
    private static let discoveryDeadline: Duration = .seconds(25)

    public static func run(metainfo: TorrentMetainfo, peerID: Data, maxPeers: Int = 300) async -> UTPProbeResult {
        let peers = Array(await discoverPeers(metainfo: metainfo, peerID: peerID).prefix(maxPeers))
        var result = UTPProbeResult()
        result.peers = peers.count

        await withTaskGroup(of: (tcp: Bool, utp: Bool).self) { group in
            var iterator = peers.makeIterator()
            func addNext() {
                guard let peer = iterator.next() else { return }
                group.addTask {
                    async let tcp = tcpReachable(peer)
                    async let utp = utpReachable(peer)
                    return (await tcp, await utp)
                }
            }
            for _ in 0..<concurrency { addNext() }
            for await outcome in group {
                if outcome.tcp { result.tcpReachable += 1 }
                if outcome.utp { result.utpReachable += 1 }
                if outcome.utp, !outcome.tcp { result.utpOnly += 1 }
                addNext()
            }
        }
        return result
    }

    private static func discoverPeers(metainfo: TorrentMetainfo, peerID: Data) async -> [PeerEndpoint] {
        await withTaskGroup(of: [PeerEndpoint]?.self) { group in
            let tracker = TrackerClient()
            for url in metainfo.announceURLs {
                group.addTask {
                    let request = TrackerRequest(
                        announceURL: url, infoHash: metainfo.infoHash, peerID: peerID,
                        downloaded: 0, left: metainfo.totalSize, event: nil
                    )
                    return (try? await tracker.announce(request)) ?? []
                }
            }
            group.addTask { (try? await DHTClient().peers(for: metainfo.infoHash)) ?? [] }
            group.addTask {
                try? await Task.sleep(for: discoveryDeadline)
                return nil
            }

            var peers = Set<PeerEndpoint>()
            for await found in group {
                guard let found else { break }
                peers.formUnion(found)
            }
            group.cancelAll()
            return Array(peers).shuffled()
        }
    }

    private static func tcpReachable(_ peer: PeerEndpoint) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: peer.port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(peer.host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "swiftorrent.utpprobe.tcp")
        let reachable = (try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(returning: true)
                case .failed, .waiting, .cancelled: once.resume(returning: false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.resume(returning: false) }
        }) ?? false
        connection.cancel()
        return reachable
    }

    /// Sends a uTP SYN (twice, 2 s apart, as a lost datagram is common) and
    /// reports whether the peer answered with an ST_STATE packet.
    private static func utpReachable(_ peer: PeerEndpoint) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: peer.port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(peer.host), port: port, using: .udp)
        let queue = DispatchQueue(label: "swiftorrent.utpprobe.udp")
        let connectionID = UInt16.random(in: 1..<UInt16.max)
        let syn = UTPPacket(
            kind: .syn, connectionID: connectionID,
            timestamp: UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1000),
            windowSize: 1 << 16, sequenceNumber: 1
        ).encoded()

        let reply = (try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UTPPacket?, Error>) in
            let once = ResumeOnce(continuation)
            @Sendable func receiveNext() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { data, _, _, error in
                    if let data, let packet = UTPPacket(data), packet.kind == .state {
                        once.resume(returning: packet)
                    } else if error != nil {
                        once.resume(returning: nil)
                    } else {
                        receiveNext()
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: syn, completion: .idempotent)
                    receiveNext()
                    queue.asyncAfter(deadline: .now() + 2) {
                        connection.send(content: syn, completion: .idempotent)
                    }
                case .failed, .waiting, .cancelled:
                    once.resume(returning: nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.resume(returning: nil) }
        }) ?? nil

        guard let reply else {
            connection.cancel()
            return false
        }
        // Tell the peer to drop the half-open connection we just created.
        let reset = UTPPacket(
            kind: .reset, connectionID: connectionID &+ 1,
            sequenceNumber: 1, ackNumber: reply.sequenceNumber
        ).encoded()
        connection.send(content: reset, completion: .contentProcessed { _ in connection.cancel() })
        return true
    }
}
