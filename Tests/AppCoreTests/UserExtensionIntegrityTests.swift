// SPDX-License-Identifier: MIT
import Testing
import Foundation
import ArchiveAdapter
@testable import AppCore
@testable import LibraryStore

/// G64: 破損チェック（spec §6.5 (d)）。「対象外」にするのは、足した拡張子のアーカイブを開く段の
/// 「unrecognized archive format」だけ。標準（tar を含む）と足していない拡張子・途中の打ち切りは今どおり「破損」。
@Suite("G64: 足した拡張子の破損チェック")
struct UserExtensionIntegrityTests {
    private let unrecognized = QuickIntegrityCheck.unrecognizedFormatReason

    @Test("簡易の分類: 足したアーカイブの unrecognized だけ対象外（理由は残す）")
    func classification() {
        let added = QuickIntegrityCheck.classify(category: .archive, exists: true, probe: .failed(reason: unrecognized),
                                                 fileSize: 10, isUserExtension: true)
        #expect(added == .init(status: .unsupported, pageCount: nil, reason: unrecognized))
        #expect(QuickIntegrityCheck.classify(category: .archive, exists: true, probe: .failed(reason: unrecognized),
                                             fileSize: 10, isUserExtension: false).status == .damaged)
        // G64 最終レビュー m1: 0 バイトは対象外にしない（サイズが取れなかった nil は今どおり）。
        #expect(QuickIntegrityCheck.classify(category: .archive, exists: true, probe: .failed(reason: unrecognized),
                                             fileSize: 0, isUserExtension: true).status == .damaged)
        #expect(QuickIntegrityCheck.classify(category: .archive, exists: true, probe: .failed(reason: unrecognized),
                                             fileSize: nil, isUserExtension: true).status == .unsupported)
        #expect(QuickIntegrityCheck.classify(category: .archive, exists: true, probe: .failed(reason: "archive read truncated"),
                                             fileSize: 10, isUserExtension: true).status == .damaged)
        #expect(QuickIntegrityCheck.classify(category: .archive, exists: true, probe: .enumerated(count: 2, truncated: true),
                                             fileSize: 10, isUserExtension: true).status == .damaged)
        #expect(QuickIntegrityCheck.classify(category: .archive, exists: true,
                                             probe: .failed(reason: "archive unreadable: could not open archive"),
                                             fileSize: 10, isUserExtension: true).status == .damaged)
    }

    private func setupDB(_ paths: [URL]) throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        for (i, url) in paths.enumerated() {
            try db.insertBook(BookRow(id: i + 1, title: url.lastPathComponent, author: nil, genre: nil, path: url.path,
                                      dateAdded: Date(), playDate: nil, bookType: 0, fileType: 2, pages: nil,
                                      rating: 0, unseen: false, keywordA: nil, keywordB: nil, keywordC: nil,
                                      neta: nil, memo: nil))
        }
        return db
    }

    /// 足した `.djvu`（でたらめ）・標準の `.cbt`（でたらめ）・足していない `.xyz`（でたらめ）・足した `.foo`（途中で切れた tar）・
    /// 標準の `.cbt`（正しい tar）。
    private func makeFiles(_ dir: URL) throws -> [URL] {
        let djvu = dir.appendingPathComponent("a.djvu"); try G64Fixtures.noise.write(to: djvu)
        let badCBT = dir.appendingPathComponent("b.cbt"); try G64Fixtures.noise.write(to: badCBT)
        let xyz = dir.appendingPathComponent("c.xyz"); try G64Fixtures.noise.write(to: xyz)
        let whole = try G64Fixtures.makeTar(at: dir.appendingPathComponent("whole.tar"))
        let cut = dir.appendingPathComponent("d.foo"); try Data(contentsOf: whole).prefix(1100).write(to: cut)
        let good = try G64Fixtures.makeTar(at: dir.appendingPathComponent("e.cbt"))
        return [djvu, badCBT, xyz, cut, good]
    }

    private let added: UserExtensionMap = ["djvu": .archive, "foo": .archive]

    @Test("簡易チェック: 足したアーカイブの読めない形式は対象外、ほかは今どおり")
    func quickScan() async throws {
        let dir = try G64Fixtures.tempDir("qi"); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try setupDB(try makeFiles(dir))
        // 一覧は走査の始めに 1 回だけ読む: 作った後に store から消しても、この走査は「足した」まま。
        let suiteName = "g64-qi-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserExtensionStore(defaults: defaults)
        store.add("djvu", category: .archive); store.add("foo", category: .archive)
        let deps = QuickIntegrityScanner.liveDependencies(archiveExtractor: LibarchiveCoverExtractor(),
                                                          folderExtractor: FolderCoverExtractor(),
                                                          userExtensions: store.snapshot)
        store.remove("djvu")
        _ = try await QuickIntegrityScanner.scan(database: db, deps: deps)

        #expect(try db.integrityRecord(bookID: 1)?.status == .unsupported)
        #expect(try db.integrityRecord(bookID: 1)?.badEntries == [unrecognized])
        #expect(try db.integrityRecord(bookID: 2)?.status == .damaged)
        #expect(try db.integrityRecord(bookID: 2)?.badEntries == [unrecognized])
        #expect(try db.integrityRecord(bookID: 3)?.status == .damaged)
        #expect(try db.integrityRecord(bookID: 4)?.status == .damaged)
        #expect(try db.integrityRecord(bookID: 4)?.badEntries == ["enumeration truncated"])
        #expect(try db.integrityRecord(bookID: 5)?.status == .ok)
        #expect(try db.fetchBook(id: 5)?.pages == 3)
        #expect(try db.fetchBook(id: 1)?.pages == nil)
    }

    @Test("詳細チェック: 足したアーカイブの読めない形式は対象外（簡易の「破損」を上書きする）、ほかは今どおり")
    func fullScan() async throws {
        let dir = try G64Fixtures.tempDir("fi"); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try setupDB(try makeFiles(dir))
        // 足す前の簡易チェックで「破損」になっていた行。
        try db.upsertIntegrity(IntegrityRecord(bookID: 1, status: .damaged, method: .quick, checkedAt: 1,
                                               fileSize: nil, fileMtime: nil, entryCount: nil,
                                               badEntries: [unrecognized], prevStatus: nil, prevCheckedAt: nil))
        let deps = FullIntegrityScanner.liveDependencies(libraryBundleURL: dir, userExtensions: added)
        _ = try await FullIntegrityScanner.scan(database: db, mode: .uncheckedOnly, deps: deps)

        #expect(try db.integrityRecord(bookID: 1)?.status == .unsupported)
        #expect(try db.integrityRecord(bookID: 1)?.method == .full)
        #expect(try db.integrityRecord(bookID: 2)?.status == .damaged)
        #expect(try db.integrityRecord(bookID: 3)?.status == .damaged)
        #expect(try db.integrityRecord(bookID: 4)?.status == .damaged)
        #expect(try db.integrityRecord(bookID: 5)?.status == .ok)
        #expect(try db.fetchBook(id: 5)?.pages == 3)
    }

    @Test("詳細チェック: テキストとして足した本の古い「破損」は上書きする・標準のテキストは今どおり触らない")
    func fullScanRewritesAddedTextButNotStandardText() async throws {
        let dir = try G64Fixtures.tempDir("fi-text"); defer { try? FileManager.default.removeItem(at: dir) }
        let docx = dir.appendingPathComponent("a.docx"); try Data("x".utf8).write(to: docx)
        let txt = dir.appendingPathComponent("b.txt"); try Data("x".utf8).write(to: txt)
        let db = try setupDB([docx, txt])
        for id in [1, 2] {
            try db.upsertIntegrity(IntegrityRecord(bookID: id, status: .damaged, method: .quick, checkedAt: 1,
                                                   fileSize: nil, fileMtime: nil, entryCount: nil,
                                                   badEntries: [unrecognized], prevStatus: nil, prevCheckedAt: nil))
        }
        let deps = FullIntegrityScanner.liveDependencies(libraryBundleURL: dir, userExtensions: ["docx": .text])
        _ = try await FullIntegrityScanner.scan(database: db, mode: .all, deps: deps)
        #expect(try db.integrityRecord(bookID: 1)?.status == .unsupported)
        #expect(try db.integrityRecord(bookID: 2)?.status == .damaged, "標準のテキストは既存の行を上書きしない（今どおり）")
    }

    // MARK: G64 最終レビュー m1: 0 バイト

    @Test("簡易チェック: 足したアーカイブの 0 バイトは破損（対象外にしない）")
    func quickScanZeroByteAddedArchiveIsDamaged() async throws {
        let dir = try G64Fixtures.tempDir("zero-quick"); defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("a.djvu"); try Data().write(to: empty)
        let noise = dir.appendingPathComponent("b.djvu"); try G64Fixtures.noise.write(to: noise)
        let db = try setupDB([empty, noise])
        let deps = QuickIntegrityScanner.liveDependencies(archiveExtractor: LibarchiveCoverExtractor(),
                                                          folderExtractor: FolderCoverExtractor(), userExtensions: added)
        _ = try await QuickIntegrityScanner.scan(database: db, deps: deps)
        #expect(try db.integrityRecord(bookID: 1)?.status == .damaged)
        #expect(try db.integrityRecord(bookID: 2)?.status == .unsupported, "でたらめなバイトは今どおり対象外")
    }

    @Test("詳細チェック: 足したアーカイブの 0 バイトは破損（対象外にしない）")
    func fullScanZeroByteAddedArchiveIsDamaged() async throws {
        let dir = try G64Fixtures.tempDir("zero-full"); defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("a.djvu"); try Data().write(to: empty)
        let noise = dir.appendingPathComponent("b.djvu"); try G64Fixtures.noise.write(to: noise)
        let db = try setupDB([empty, noise])
        let deps = FullIntegrityScanner.liveDependencies(libraryBundleURL: dir, userExtensions: added)
        _ = try await FullIntegrityScanner.scan(database: db, mode: .all, deps: deps)
        #expect(try db.integrityRecord(bookID: 1)?.status == .damaged)
        #expect(try db.integrityRecord(bookID: 2)?.status == .unsupported, "でたらめなバイトは今どおり対象外")
    }
}
