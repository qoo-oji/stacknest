// SPDX-License-Identifier: MIT
import Testing
import Foundation
import ArchiveAdapter
@testable import AppCore
@testable import LibraryStore

/// G64 最終レビュー I1（作者の決定 d）: gzip で包んだ tar を読んでよいのは、ユーザーがアーカイブとして足した拡張子だけ。
/// 標準の `.cbt`・`.tar` と未知の拡張子は、外側の圧縮の無い tar だけを読む。
@Suite("G64: gzip の tar は足した拡張子だけ")
struct UserExtensionCompressedTarTests {
    private let added: UserExtensionMap = ["tgz": .archive, "djvu": .archive]

    /// gzip で包んだ tar を `name` で作る。
    private func gzTar(_ dir: URL, _ name: String) throws -> URL {
        try G64Fixtures.makeTar(at: dir.appendingPathComponent(name), gzip: true)
    }

    // MARK: 抽出器・内蔵ビューア

    @Test("足したアーカイブの抽出器だけ gzip の tar を読む（一覧と表紙）")
    func extractorsReadGzipOnlyForAdded() async throws {
        let dir = try G64Fixtures.tempDir("gz-ext"); defer { try? FileManager.default.removeItem(at: dir) }
        let tgz = try gzTar(dir, "a.tgz")
        let cbt = try gzTar(dir, "b.cbt")

        let extractor = try #require(BookExtractors.coverExtractor(for: tgz, userExtensions: added))
        #expect(try await extractor.listImageEntries(in: tgz).names.count == 3)
        #expect(try await extractor.extractCoverImage(from: tgz, preferredName: nil) == G64Fixtures.pagePNG(1))
        let importer = try #require(BookExtractors.importExtractor(for: tgz, userExtensions: added))
        #expect(try await importer.countImageEntries(in: tgz).count == 3)

        // 標準の .cbt は gzip の tar を読まない（足した一覧が空でも、tgz を足していても同じ）。
        for map in [UserExtensionMap(), added] {
            let std = try #require(BookExtractors.coverExtractor(for: cbt, userExtensions: map))
            await #expect(throws: ArchiveAdapterError.self) { _ = try await std.listImageEntries(in: cbt) }
        }
    }

    @Test("内蔵ビューア: 足した tgz は gzip の tar を読める・標準の cbt と未知の拡張子は読めない・素の cbt は読める")
    func contentFollowsTheSameRule() async throws {
        let dir = try G64Fixtures.tempDir("gz-content"); defer { try? FileManager.default.removeItem(at: dir) }
        let tgz = try gzTar(dir, "a.tgz")
        let cbt = try gzTar(dir, "b.cbt")
        let xyz = try gzTar(dir, "c.xyz")
        let plain = try G64Fixtures.makeTar(at: dir.appendingPathComponent("d.cbt"))

        let ok = try BookContentFactory.make(path: tgz.path, userExtensions: added)
        #expect(try await ok.pageCount == 3)
        #expect(try await ok.imageData(at: 0) == G64Fixtures.pagePNG(1))
        #expect(try await BookContentFactory.make(path: plain.path, userExtensions: added).pageCount == 3)
        for url in [cbt, xyz] {
            let content = try BookContentFactory.make(path: url.path, userExtensions: added)
            await #expect(throws: (any Error).self) { _ = try await content.pageCount }
        }
    }

    // MARK: 破損チェック

    private func setupDB(_ urls: [URL]) throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        for (i, url) in urls.enumerated() {
            try db.insertBook(BookRow(id: i + 1, title: url.lastPathComponent, author: nil, genre: nil, path: url.path,
                                      dateAdded: Date(), playDate: nil, bookType: 0, fileType: 2, pages: nil,
                                      rating: 0, unseen: false, keywordA: nil, keywordB: nil, keywordC: nil,
                                      neta: nil, memo: nil))
        }
        return db
    }

    /// 1: 標準の .cbt（gzip の tar）・2: 未知の .xyz（gzip の tar）・3: 足した .tgz（gzip の tar）・4: 素の .cbt。
    private func makeFiles(_ dir: URL) throws -> [URL] {
        [try gzTar(dir, "a.cbt"), try gzTar(dir, "b.xyz"), try gzTar(dir, "c.tgz"),
         try G64Fixtures.makeTar(at: dir.appendingPathComponent("d.cbt"))]
    }

    @Test("簡易チェック: gzip の標準 .cbt と未知の拡張子は破損・足した .tgz と素の .cbt は読める")
    func quickScanVerdicts() async throws {
        let dir = try G64Fixtures.tempDir("gz-quick"); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try setupDB(try makeFiles(dir))
        let deps = QuickIntegrityScanner.liveDependencies(archiveExtractor: LibarchiveCoverExtractor(),
                                                          folderExtractor: FolderCoverExtractor(), userExtensions: added)
        _ = try await QuickIntegrityScanner.scan(database: db, deps: deps)
        #expect(try db.integrityRecord(bookID: 1)?.status == .damaged)
        #expect(try db.integrityRecord(bookID: 2)?.status == .damaged)
        #expect(try db.integrityRecord(bookID: 3)?.status == .ok)
        #expect(try db.fetchBook(id: 3)?.pages == 3)
        #expect(try db.integrityRecord(bookID: 4)?.status == .ok)
        #expect(try db.fetchBook(id: 4)?.pages == 3)
    }

    @Test("詳細チェック: gzip の標準 .cbt と未知の拡張子は破損・足した .tgz と素の .cbt は読める")
    func fullScanVerdicts() async throws {
        let dir = try G64Fixtures.tempDir("gz-full"); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try setupDB(try makeFiles(dir))
        let deps = FullIntegrityScanner.liveDependencies(libraryBundleURL: dir, userExtensions: added)
        _ = try await FullIntegrityScanner.scan(database: db, mode: .all, deps: deps)
        #expect(try db.integrityRecord(bookID: 1)?.status == .damaged)
        #expect(try db.integrityRecord(bookID: 2)?.status == .damaged)
        #expect(try db.integrityRecord(bookID: 3)?.status == .ok)
        #expect(try db.fetchBook(id: 3)?.pages == 3)
        #expect(try db.integrityRecord(bookID: 4)?.status == .ok)
    }
}
