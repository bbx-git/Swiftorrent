import Foundation

public enum PeerWireError: Error, LocalizedError {
    case connectionFailed
    case invalidHandshake
    case disconnected
    case unexpectedMessage
    case invalidPieceHash
    case extensionProtocolUnavailable
    case metadataUnavailable
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .connectionFailed: "Could not connect to peer."
        case .invalidHandshake: "Peer returned an invalid BitTorrent handshake."
        case .disconnected: "Peer disconnected."
        case .unexpectedMessage: "Peer returned an unexpected message."
        case .invalidPieceHash: "Downloaded piece failed SHA-1 verification."
        case .extensionProtocolUnavailable: "Peer does not support the BitTorrent extension protocol."
        case .metadataUnavailable: "Peer does not provide magnet metadata."
        case .timedOut: "Peer stopped responding."
        }
    }
}
