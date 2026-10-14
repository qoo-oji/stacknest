// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AppCore

/// G64 のテスト用の部品（足した拡張子・tar・Quick Look の偽物）。
enum G64Fixtures {
    /// 一時ディレクトリ（呼び出し側が消す）。
    static func tempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// PNG（`width`×`height`・不透明の灰色）。
    static func png(width: Int = 4, height: Int = 4, alpha: Bool = false) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !alpha {
            ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// でたらめなバイト（どの形式の印にも当たらない並び）。
    static let noise = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

    /// PNG 3 枚の tar を `/usr/bin/tar` で作る（`gzip` なら gzip で包む）。中の順は page1・page3・page2。
    @discardableResult
    static func makeTar(at url: URL, gzip: Bool = false) throws -> URL {
        let src = url.deletingLastPathComponent().appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: src) }
        for name in ["page1.png", "page2.png", "page3.png"] { try png().write(to: src.appendingPathComponent(name)) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.environment = ["COPYFILE_DISABLE": "1"]   // `._` のエントリを入れない
        process.arguments = [gzip ? "-czf" : "-cf", url.path, "-C", src.path, "page1.png", "page3.png", "page2.png"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "G64Fixtures.tar", code: Int(process.terminationStatus)) }
        return url
    }

    /// 2 秒の mp4（AppCoreTests の VideoFixtures）を `name` の名前で写す。
    static func copySampleVideo(to url: URL) throws -> URL {
        let src = try requireURL(Bundle.module.url(forResource: "sample-2s", withExtension: "mp4", subdirectory: "VideoFixtures"))
        try FileManager.default.copyItem(at: src, to: url)
        return url
    }

    /// 中に PDF（5 ページ）だけがある zip（AppCoreTests の PDFFixtures）を写す。
    static func copyPDFOnlyZip(to url: URL) throws -> URL {
        let src = try requireURL(Bundle.module.url(forResource: "pdf-only", withExtension: "zip", subdirectory: "PDFFixtures"))
        try FileManager.default.copyItem(at: src, to: url)
        return url
    }

    private static func requireURL(_ url: URL?) throws -> URL {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return url
    }

    /// JPEG か（先頭が FFD8）。
    static func isJPEG(_ data: Data?) -> Bool { data?.prefix(2) == Data([0xFF, 0xD8]) }
}

/// Quick Look の偽物。呼ばれた URL を数え、決めた結果を返す。
final class FakeThumbnailer: CoverThumbnailing, @unchecked Sendable {
    /// 偽物が返す JPEG（中身の判別用に固定のバイト列）。
    static let marker = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x47, 0x36, 0x34])
    private let lock = NSLock()
    private var urls: [URL] = []
    private let result: Data?

    init(result: Data? = FakeThumbnailer.marker) { self.result = result }

    var calls: [URL] { lock.withLock { urls } }

    func coverJPEG(for url: URL, maxPixelSize: Int) async -> Data? {
        lock.withLock { urls.append(url) }
        return result
    }
}
