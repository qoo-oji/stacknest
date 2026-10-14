// SPDX-License-Identifier: MIT
import Testing
import Foundation
import ArchiveAdapter
@testable import AppCore

/// G64: 抽出器の振り分け（spec §6.4）。足したアーカイブは libarchive、ほかの足した種類は無し、標準は ArchiveAdapter のまま。
@Suite("G64: 抽出器の振り分け")
struct BookExtractorsTests {
    private let added: UserExtensionMap = ["tgz": .archive, "avif": .image, "docx": .text, "3gp": .video]

    @Test("足したアーカイブは libarchive（表紙候補用・取り込み用とも）")
    func addedArchiveUsesLibarchive() {
        let url = URL(fileURLWithPath: "/tmp/a.TGZ")
        #expect(BookExtractors.coverExtractor(for: url, userExtensions: added) is LibarchiveCoverExtractor)
        #expect(BookExtractors.importExtractor(for: url, userExtensions: added) is LibarchiveCoverExtractor)
    }

    @Test("足した画像・テキスト・動画と、足していない拡張子は無し", arguments: ["a.avif", "a.docx", "a.3gp", "a.djvu"])
    func otherAddedCategoriesHaveNone(name: String) {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        #expect(BookExtractors.coverExtractor(for: url, userExtensions: added) == nil)
        #expect(BookExtractors.importExtractor(for: url, userExtensions: added) == nil)
    }

    @Test("標準は ArchiveAdapter のまま（cbt・PDF・EPUB を含む）")
    func standardFollowsArchiveAdapter() {
        #expect(BookExtractors.coverExtractor(for: URL(fileURLWithPath: "/tmp/a.cbt"), userExtensions: [:]) is LibarchiveCoverExtractor)
        #expect(BookExtractors.importExtractor(for: URL(fileURLWithPath: "/tmp/a.cbz"), userExtensions: [:]) is LibarchiveCoverExtractor)
        #expect(BookExtractors.coverExtractor(for: URL(fileURLWithPath: "/tmp/a.pdf"), userExtensions: [:]) is PDFCoverExtractor)
        #expect(BookExtractors.importExtractor(for: URL(fileURLWithPath: "/tmp/a.pdf"), userExtensions: [:]) == nil)
        #expect(BookExtractors.importExtractor(for: URL(fileURLWithPath: "/tmp/a.epub"), userExtensions: [:]) == nil)
        // 一覧に標準と重なる項目が紛れても標準が勝つ（pdf を足したアーカイブとして扱わない）。
        #expect(BookExtractors.importExtractor(for: URL(fileURLWithPath: "/tmp/a.pdf"), userExtensions: ["pdf": .archive]) == nil)
    }

    @Test("足した拡張子の名前のディレクトリはフォルダ")
    func directoryIsAFolder() throws {
        let dir = try G64Fixtures.tempDir("extr").appendingPathComponent("book.tgz", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        #expect(BookExtractors.coverExtractor(for: dir, userExtensions: added) is FolderCoverExtractor)
        #expect(BookExtractors.importExtractor(for: dir, userExtensions: added) is FolderCoverExtractor)
    }
}
