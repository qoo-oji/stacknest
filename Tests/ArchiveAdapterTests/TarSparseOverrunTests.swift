// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter
import Carchive

/// G64 fix1: tar の申告サイズを超えて出続けるデータ（GNU sparse の穴の 0 埋め）の上限と、予算まわりの穴埋め。
@Suite("G64: tar の申告サイズ超過・予算の穴埋め")
struct TarSparseOverrunTests {
    /// レビューの細工: 古い GNU の sparse（`S`）、実サイズ 0、sparse[0].offset = 2^37（base-256）、格納 512 バイト。
    static func sparseBomb(offsetShift: Int = 37) -> Data {
        var tar = TarArchiveTests.ustarHeader(name: "sparse.png", size: 512, type: "S", gnu: true) { h in
            h[386] = 0x80; var v: UInt64 = 1 << UInt64(offsetShift)
            for i in stride(from: 397, through: 387, by: -1) { h[i] = UInt8(v & 0xFF); v >>= 8 }
            for (i, b) in "00000001000".utf8.enumerated() { h[398 + i] = b }
            h[482] = 0
            for (i, b) in "00000000000".utf8.enumerated() { h[483 + i] = b }
        }
        tar += Data(repeating: UInt8(ascii: "A"), count: 512) + Data(count: 1024)
        return tar
    }

    static func bombFile(gzip: Bool) throws -> (url: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-bomb2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("bomb.cbt")
        if gzip { try TarArchiveTests.compress(sparseBomb(), with: "gzip", to: url) }
        else { try sparseBomb().write(to: url) }
        return (url, dir)
    }

    @Test("sparse の穴の 0 埋めは申告サイズで止まり、詳細チェックは破損として返す", arguments: [false, true])
    func verifierStopsSparseZeroFill(gzip: Bool) throws {
        let (url, dir) = try Self.bombFile(gzip: gzip)
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date()
        let result = try ArchiveIntegrityVerifier.verifySync(url: url, allowsCompressedTar: gzip)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(result.badEntries == ["sparse.png"])
        #expect(result.entryCount == 1 && result.truncated == false)
    }

    @Test("順方向の取り出しは sparse の 0 埋めを申告サイズで止めて投げる", arguments: [false, true])
    func sequentialStopsSparseZeroFill(gzip: Bool) async throws {
        let (url, dir) = try Self.bombFile(gzip: gzip)
        defer { try? FileManager.default.removeItem(at: dir) }
        let seq = SequentialArchiveExtractor(url: url, imageNames: ["sparse.png"], allowsCompressedTar: gzip)
        let start = Date()
        await #expect {
            _ = try await seq.data(forName: "sparse.png")
        } throws: { error in
            guard case .archiveUnreadable(_, let reason) = error as? ArchiveAdapterError else { return false }
            return reason == TarWalkBudget.overrunReason
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    /// 対照: 申告サイズどおりに出る普通の tar は、申告サイズの上限に掛からない。
    @Test("普通の tar は申告サイズの上限に掛からない")
    func ordinaryTarIsNotFlagged() throws {
        let (url, dir, _) = try TarArchiveTests.makeTar(named: "book.cbt")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try ArchiveIntegrityVerifier.verifySync(url: url).badEntries.isEmpty)
    }

    /// 512 バイト境界に詰めた 1 エントリ。
    static func entry(_ name: String, _ body: Data) -> Data {
        let pad = (512 - body.count % 512) % 512
        return TarArchiveTests.ustarHeader(name: name, size: UInt64(body.count)) + body + Data(count: pad)
    }

    /// m1: PDF 一覧の予算。PDF がエントリの上限より後ろにある tar は、上限で打ち切られて PDF が見つからない（開けない）。
    @Test("PDF の一覧にも歩く量の上限が効く")
    func pdfListingHonoursEntryLimit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("with-pdf.cbt")
        try (Self.entry("a.png", Data("aa".utf8)) + Self.entry("b.png", Data("bb".utf8))
             + Self.entry("doc.pdf", Data("%PDF-1.4".utf8)) + Data(count: 1024)).write(to: url)
        // 上限が十分なら PDF が取れる（対照）。
        #expect(try await LibarchiveCoverExtractor().extractFirstPDFData(in: url) == Data("%PDF-1.4".utf8))
        // 上限が 2 エントリなら、PDF は上限の外。
        let limits = TarWalkLimits(maxEntries: 2, baseBytes: 1 << 30, bytesPerFileByte: 0, maxScaledBytes: 0)
        await #expect(throws: ArchiveAdapterError.self) {
            _ = try await LibarchiveCoverExtractor(walkLimits: limits).extractFirstPDFData(in: url)
        }
    }

    /// m2: シンボリックリンクの本は、リンク先のファイルの大きさで上限を決める。
    @Test("シンボリックリンクの本の上限はリンク先の大きさで決まる")
    func walkLimitFollowsSymlinks() async throws {
        let (url, dir, _) = try TarArchiveTests.makeTar(named: "real.cbt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("link.cbt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        // 固定の部分が 0・大きさの 1 倍だけ歩ける。リンク自身の大きさ（数十バイト）で決めると 1 つ目のヘッダも歩けない。
        let limits = TarWalkLimits(maxEntries: 100, baseBytes: 0, bytesPerFileByte: 1, maxScaledBytes: 1 << 30)
        let listing = try await LibarchiveCoverExtractor(walkLimits: limits).listImageEntries(in: link)
        #expect(listing.names.count == 3 && listing.truncated == false)
    }

    /// mac-ext を切っているので、`._x.png` は AppleDouble として食われず、普通のエントリとして並ぶ。
    @Test("`._` のエントリは普通のエントリとして見える（mac-ext を切っている）")
    func appleDoubleEntryIsOrdinary() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-mac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mac.cbt")
        try (Self.entry("._x.png", Data("AAAA".utf8)) + Self.entry("x.png", Data("xx".utf8)) + Data(count: 1024)).write(to: url)
        let listing = try await LibarchiveCoverExtractor().listImageEntries(in: url)
        #expect(listing.names == ["._x.png", "x.png"])
    }
}
