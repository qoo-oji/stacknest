// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter

/// G64 Codex fix: tar の AppleDouble（`._名前`）は画像・PDF の候補にも数にも入れない。
/// zip の `__MACOSX/` と folder は今のまま（ここで挙動を固定する）。
@Suite("G64: tar の AppleDouble")
struct TarAppleDoubleTests {
    static let appleDoubleBytes = Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00] + [UInt8](repeating: 0, count: 40))

    /// `members` の (名前, 中身) を src に書き、`tool` で書庫にする。
    static func make(named fileName: String, tool: String, args: [String], members: [(String, Data)]) throws -> (url: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-ad-\(UUID().uuidString)")
        let src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for (name, data) in members {
            let f = src.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: f)
        }
        let url = dir.appendingPathComponent(fileName)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.currentDirectoryURL = src
        p.environment = ["COPYFILE_DISABLE": "1"]
        p.arguments = args.map { $0 == "{out}" ? url.path : $0 } + members.map { $0.0 }
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "AD", code: Int(p.terminationStatus)) }
        return (url, dir)
    }

    static func tar(_ members: [(String, Data)], named: String = "book.cbt") throws -> (url: URL, dir: URL) {
        try make(named: named, tool: "/usr/bin/tar", args: ["-cf", "{out}"], members: members)
    }

    @Test("tar: 画像の数・一覧・表紙は `._` を除いた 001.jpg から")
    func imagesSkipAppleDouble() async throws {
        let png1 = try LibarchiveCoverExtractorTests.make1x1PNG(r: 1, g: 2, b: 3)
        let png2 = try LibarchiveCoverExtractorTests.make1x1PNG(r: 4, g: 5, b: 6)
        let (url, dir) = try Self.tar([("._001.jpg", Self.appleDoubleBytes), ("001.jpg", png1), ("002.jpg", png2)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let ex = LibarchiveCoverExtractor()
        #expect(try await ex.listImageEntries(in: url).names == ["001.jpg", "002.jpg"])
        #expect(try await ex.countImageEntries(in: url).count == 2)
        #expect(try await ex.extractCoverImage(from: url) == png1)
        #expect(try await ex.extractCoverImage(from: url, preferredName: nil) == png1)
    }

    @Test("tar: 入れ子の `dir/._x.jpg` も除く。`._` で始まらない名前は残す")
    func nestedAndLookalikes() async throws {
        let png = try LibarchiveCoverExtractorTests.make1x1PNG(r: 1, g: 2, b: 3)
        let (url, dir) = try Self.tar([("d/._a.jpg", Self.appleDoubleBytes), ("d/a.jpg", png), ("_b.jpg", png), ("c._d.jpg", png)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = try await LibarchiveCoverExtractor().listImageEntries(in: url).names
        #expect(Set(names) == ["d/a.jpg", "_b.jpg", "c._d.jpg"])
    }

    @Test("tar: 整合性の検査は `._` を数えず、壊れとも言わない")
    func verifierSkipsAppleDouble() throws {
        let png1 = try LibarchiveCoverExtractorTests.make1x1PNG(r: 1, g: 2, b: 3)
        let png2 = try LibarchiveCoverExtractorTests.make1x1PNG(r: 4, g: 5, b: 6)
        let (url, dir) = try Self.tar([("._001.jpg", Self.appleDoubleBytes), ("001.jpg", png1), ("002.jpg", png2)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try ArchiveIntegrityVerifier.verifySync(url: url)
        #expect(r.imageCount == 2)
        #expect(r.entryCount == 2)
        #expect(r.badEntries.isEmpty && r.truncated == false)
    }

    @Test("tar: PDF の代わりは本物の book.pdf（`._book.pdf` ではない）")
    func pdfFallbackSkipsAppleDouble() async throws {
        let pdf = Data("%PDF-1.4 real".utf8)
        let (url, dir) = try Self.tar([("._book.pdf", Self.appleDoubleBytes), ("book.pdf", pdf)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let ex = LibarchiveCoverExtractor()
        #expect(try await ex.extractFirstPDFData(in: url) == pdf)
        #expect(try await ex.countImageEntries(in: url).count == 0)
    }

    /// 今の挙動の固定: zip の `__MACOSX/._x` は libarchive の zip 読み（mac-ext 既定）が一覧から外す。
    /// この修正は zip・folder に触れない（触ると既存の zip 本のページ番号が動く）。
    @Test("zip: `__MACOSX/._001.jpg` の今の扱いを固定する（変えない）")
    func zipUnchanged() async throws {
        let png = try LibarchiveCoverExtractorTests.make1x1PNG(r: 1, g: 2, b: 3)
        let (url, dir) = try Self.make(named: "book.cbz", tool: "/usr/bin/zip", args: ["-q", "{out}"],
                                       members: [("__MACOSX/._001.jpg", Self.appleDoubleBytes), ("001.jpg", png)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let ex = LibarchiveCoverExtractor()
        #expect(try await ex.listImageEntries(in: url).names == ["001.jpg"])
        #expect(try await ex.countImageEntries(in: url).count == 1)
        #expect(try ArchiveIntegrityVerifier.verifySync(url: url).imageCount == 1)
    }

    @Test("zip の形をした足した拡張子（tar ではない）でも `._` を除かない")
    func zipUnderUserExtensionUnchanged() async throws {
        let png = try LibarchiveCoverExtractorTests.make1x1PNG(r: 1, g: 2, b: 3)
        let (url, dir) = try Self.make(named: "book.myz", tool: "/usr/bin/zip", args: ["-q", "{out}"],
                                       members: [("._001.jpg", Self.appleDoubleBytes), ("001.jpg", png)])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await LibarchiveCoverExtractor().countImageEntries(in: url).count == 2)
    }
}
