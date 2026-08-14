import Foundation
import SwiftorrentCore

// Headless benchmark harness for Swiftorrent's download engine.
//
// Drives `SwiftorrentCore.TorrentDownloader` directly (the same engine the GUI
// app uses) and logs machine-readable throughput so the client can be compared
// apples-to-apples against CLI clients like aria2c and Transmission.
//
// Usage:
//   swiftorrent-bench --torrent <path> [--dest <dir>] [--label <name>]
//   swiftorrent-bench --magnet "<magnet:...>" [--dest <dir>] [--label <name>]
//
// A fresh unique destination is used per run unless --dest is given, so every
// benchmark starts from a cold cache.

// Line-buffer stdout so progress lines stream live even when redirected to a
// file or pipe (Swift `print` block-buffers to a pipe by default).
setvbuf(stdout, nil, _IOLBF, 0)

struct Args {
    var torrentPath: String?
    var magnet: String?
    var dest: String?
    var label: String = "swiftorrent"
}

func parseArgs() -> Args {
    var args = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let flag = it.next() {
        switch flag {
        case "--torrent": args.torrentPath = it.next()
        case "--magnet": args.magnet = it.next()
        case "--dest": args.dest = it.next()
        case "--label": args.label = it.next() ?? args.label
        default:
            FileHandle.standardError.write(Data("Unknown argument: \(flag)\n".utf8))
        }
    }
    return args
}

func seconds(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) + Double(c.attoseconds) / 1e18
}

func mib(_ bytesPerSecond: Double) -> String {
    String(format: "%.2f MiB/s", bytesPerSecond / 1_048_576)
}

func mibSize(_ bytes: Int64) -> String {
    String(format: "%.1f MiB", Double(bytes) / 1_048_576)
}

/// Serializes progress samples and prints a throttled (~1s) throughput line.
actor Meter {
    let label: String
    let start = ContinuousClock.now
    private var lastTime: ContinuousClock.Instant
    private var lastBytes: Int64 = 0
    private var peak: Double = 0
    private var total: Int64 = 0
    private var firstByteAt: ContinuousClock.Instant?

    init(label: String) {
        self.label = label
        self.lastTime = ContinuousClock.now
    }

    func update(_ p: TorrentDownloadProgress) {
        total = p.totalBytes
        if firstByteAt == nil, p.downloadedBytes > 0 {
            firstByteAt = ContinuousClock.now
            let ttfb = seconds(ContinuousClock.now - start)
            print(String(format: "[%@] first byte at %.1fs", label, ttfb))
        }
        let now = ContinuousClock.now
        let sinceLast = seconds(now - lastTime)
        guard sinceLast >= 1.0 else { return }
        let delta = max(0, p.downloadedBytes - lastBytes)
        let inst = Double(delta) / sinceLast
        peak = max(peak, inst)
        let elapsed = seconds(now - start)
        let avg = elapsed > 0 ? Double(p.downloadedBytes) / elapsed : 0
        let pct = total > 0 ? Double(p.downloadedBytes) / Double(total) * 100 : 0
        print(String(format: "[%@] %5.1fs  %6.1f%%  %@ / %@  inst %@  avg %@",
                     label, elapsed, pct,
                     mibSize(p.downloadedBytes), mibSize(total),
                     mib(inst), mib(avg)))
        lastTime = now
        lastBytes = p.downloadedBytes
    }

    func summary() {
        let elapsed = seconds(ContinuousClock.now - start)
        let avg = elapsed > 0 ? Double(total) / elapsed : 0
        let ttfb = firstByteAt.map { seconds($0 - start) } ?? -1
        print("──────── \(label) summary ────────")
        print(String(format: "  total:        %@", mibSize(total)))
        print(String(format: "  wall time:    %.1fs", elapsed))
        print(String(format: "  time to first byte: %.1fs", ttfb))
        print(String(format: "  average:      %@", mib(avg)))
        print(String(format: "  peak (1s):    %@", mib(peak)))
        print("──────────────────────────────────")
    }
}

// MARK: - Main

let args = parseArgs()

let destURL: URL
if let d = args.dest {
    destURL = URL(fileURLWithPath: d, isDirectory: true)
} else {
    destURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftorrent-bench-\(UUID().uuidString)", isDirectory: true)
}

let metainfo: TorrentMetainfo
do {
    if let path = args.torrentPath {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        metainfo = try TorrentMetainfoParser().parse(data: data)
    } else if let magnet = args.magnet {
        let link = try MagnetLinkParser().parse(magnet)
        print("[\(args.label)] resolving magnet metadata…")
        let resolveStart = ContinuousClock.now
        metainfo = try await MagnetMetadataResolver().resolve(magnet: link) { prog in
            FileHandle.standardError.write(Data("  \(prog.status)\r".utf8))
        }
        print(String(format: "[%@] metadata resolved in %.1fs", args.label, seconds(ContinuousClock.now - resolveStart)))
    } else {
        FileHandle.standardError.write(Data("Provide --torrent <path> or --magnet <string>\n".utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("Failed to obtain metadata: \(error)\n".utf8))
    exit(1)
}

let totalBytes = metainfo.files.reduce(Int64(0)) { $0 + $1.length }
print("[\(args.label)] name: \(metainfo.name)")
print("[\(args.label)] size: \(mibSize(totalBytes)) across \(metainfo.files.count) file(s)")
print("[\(args.label)] dest: \(destURL.path)")

let meter = Meter(label: args.label)
do {
    try await TorrentDownloader().download(metainfo: metainfo, destination: destURL) { progress in
        await meter.update(progress)
    }
    await meter.summary()
} catch {
    FileHandle.standardError.write(Data("Download failed: \(error)\n".utf8))
    await meter.summary()
    exit(1)
}
