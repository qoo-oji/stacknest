// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryStore
@testable import AppCore

/// G64: 取り込み（spec §6.7・§6.5 (e)・§6.6）。Quick Look は偽物。
@Suite("G64: 標準の tar と足した拡張子の取り込み")
struct BookImporterUserExtensionTests {
    private func makeImporter(_ fake: FakeThumbnailer) throws -> (BookImporter, Database, URL) {
        let dir = try G64Fixtures.tempDir("imp")
        let db = try Database.openInMemory()
        try db.migrate()
        let importer = BookImporter(database: db, bundleURL: dir, format: try FilenameFormat(raw: "@title"),
                                    thumbnailer: fake)
        return (importer, db, dir)
    }

    private func thumbnail(_ dir: URL, _ id: Int) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent("Thumbnails/\(id)/thumbnail.jpg"))
    }

    private func add(_ importer: BookImporter, _ url: URL, _ added: UserExtensionMap,
                     autoClassify: Bool = true) async -> BookImporter.ImportResult {
        await importer.add(urls: [url], autoClassifyEnabled: autoClassify, thickThreshold: 100,
                           preferEPUBTitle: false, userExtensions: added)
    }

    @Test("標準の cbt・tar と足した tgz: ページ数と先頭の画像の表紙（Quick Look は呼ばない）",
          arguments: [("a.cbt", false, false), ("a.tar", false, false), ("a.tgz", true, true)])
    func tarBooksGetPagesAndCover(name: String, gzip: Bool, addTgz: Bool) async throws {
        let fake = FakeThumbnailer()
        let (importer, db, dir) = try makeImporter(fake); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try G64Fixtures.makeTar(at: dir.appendingPathComponent(name), gzip: gzip)
        let r = await add(importer, url, addTgz ? ["tgz": .archive] : [:])
        let id = try #require(r.addedIDs.first)
        let book = try #require(try db.fetchBook(id: id))
        #expect(book.pages == 3)
        #expect(book.bookType == 1, "3 ページは閾値 100 未満なので薄い本")
        #expect(book.fileType == 2)
        #expect(thumbnail(dir, id) == G64Fixtures.png())
        #expect(r.coverFailures.isEmpty)
        #expect(fake.calls.isEmpty)
    }

    @Test("読めない足したアーカイブ: ページ数を書かず、本の種類は厚い本（0）、表紙は Quick Look")
    func unreadableAddedArchive() async throws {
        let fake = FakeThumbnailer()
        let (importer, db, dir) = try makeImporter(fake); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.djvu"); try G64Fixtures.noise.write(to: url)
        let r = await add(importer, url, ["djvu": .archive])
        let id = try #require(r.addedIDs.first)
        let book = try #require(try db.fetchBook(id: id))
        #expect(book.pages == nil)
        #expect(book.bookType == 0)
        #expect(thumbnail(dir, id) == FakeThumbnailer.marker)
        #expect(fake.calls == [url])
        #expect(r.coverFailures.isEmpty)
    }

    @Test("Quick Look も失敗したら coverFailures（取り込みは続く）")
    func quickLookFailureIsACoverFailure() async throws {
        let fake = FakeThumbnailer(result: nil)
        let (importer, _, dir) = try makeImporter(fake); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.djvu"); try G64Fixtures.noise.write(to: a)
        let b = dir.appendingPathComponent("b.docx"); try Data("x".utf8).write(to: b)
        let r = await importer.add(urls: [a, b], autoClassifyEnabled: true, thickThreshold: 100,
                                   preferEPUBTitle: false, userExtensions: ["djvu": .archive, "docx": .text])
        #expect(r.addedIDs.count == 2)
        #expect(Set(r.coverFailures) == [a, b])
    }

    @Test("足した画像: 1 ページ・表紙は JPEG（元が小さな PNG でも）")
    func addedImage() async throws {
        let fake = FakeThumbnailer()
        let (importer, db, dir) = try makeImporter(fake); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.foo"); try G64Fixtures.png().write(to: url)
        let r = await add(importer, url, ["foo": .image])
        let id = try #require(r.addedIDs.first)
        #expect(try db.fetchBook(id: id)?.pages == 1)
        #expect(try db.fetchBook(id: id)?.bookType == 3)
        let thumb = thumbnail(dir, id)
        #expect(G64Fixtures.isJPEG(thumb) && thumb != FakeThumbnailer.marker)
        #expect(fake.calls.isEmpty)
    }

    @Test("足したテキスト: Quick Look だけ・ページ数なし・本の種類はテキスト（4）")
    func addedText() async throws {
        let fake = FakeThumbnailer()
        let (importer, db, dir) = try makeImporter(fake); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.docx"); try Data("x".utf8).write(to: url)
        let r = await add(importer, url, ["docx": .text])
        let id = try #require(r.addedIDs.first)
        #expect(try db.fetchBook(id: id)?.pages == nil)
        #expect(try db.fetchBook(id: id)?.bookType == 4)
        #expect(thumbnail(dir, id) == FakeThumbnailer.marker)
        #expect(fake.calls == [url])
    }

    @Test("足した動画: AVFoundation を先に試す（Quick Look は呼ばない）・本の種類は動画（5）")
    func addedVideo() async throws {
        let fake = FakeThumbnailer()
        let (importer, db, dir) = try makeImporter(fake); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try G64Fixtures.copySampleVideo(to: dir.appendingPathComponent("a.3gp"))
        let r = await add(importer, url, ["3gp": .video])
        let id = try #require(r.addedIDs.first)
        #expect(try db.fetchBook(id: id)?.bookType == 5)
        let thumb = thumbnail(dir, id)
        #expect(G64Fixtures.isJPEG(thumb) && thumb != FakeThumbnailer.marker)
        #expect(fake.calls.isEmpty)
    }

    @Test("標準の形式と足していない拡張子では Quick Look を呼ばない（今のまま）")
    func standardFormatsNeverCallQuickLook() async throws {
        let fake = FakeThumbnailer()
        let (importer, db, dir) = try makeImporter(fake); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("a.png"); try G64Fixtures.png().write(to: png)
        let txt = dir.appendingPathComponent("a.txt"); try Data("x".utf8).write(to: txt)
        let mp4 = try G64Fixtures.copySampleVideo(to: dir.appendingPathComponent("a.mp4"))
        let djvu = dir.appendingPathComponent("a.djvu"); try G64Fixtures.noise.write(to: djvu)
        let r = await importer.add(urls: [png, txt, mp4, djvu], autoClassifyEnabled: true, thickThreshold: 100,
                                   preferEPUBTitle: false, userExtensions: ["foo": .image])
        #expect(r.addedIDs.count == 4)
        #expect(fake.calls.isEmpty)
        // 足していない .djvu は今どおり未知＝アーカイブ・0 ページとして薄い本（1）・表紙なし。
        let unknown = try #require(try db.fetchAllBooks().first { $0.path == djvu.path })
        #expect(unknown.bookType == 1 && unknown.pages == nil)
        #expect(r.coverFailures.contains(djvu) && r.coverFailures.contains(txt))
    }
}
