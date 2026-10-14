import UniformTypeIdentifiers

extension UTType {
    static let torrent = UTType(filenameExtension: "torrent") ?? .data
}
