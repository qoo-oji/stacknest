// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G64: 足した拡張子の本を読めるか（spec §6.5）。標準の画像は今どおり確かめない。
@Suite("G64: 足した拡張子の本を読む")
struct UserExtensionReadingTests {
    @Test("足した画像で ImageIO が読めなければ unsupported(.image)・読めれば 1 ページ")
    func addedImageIsCheckedWithImageIO() async throws {
        let dir = try G64Fixtures.tempDir("read-img"); defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("bad.foo")
        let good = dir.appendingPathComponent("good.foo")
        try G64Fixtures.noise.write(to: bad)
        try G64Fixtures.png().write(to: good)
        let added: UserExtensionMap = ["foo": .image]
        #expect(throws: BookContentError.unsupported(.image)) {
            _ = try BookContentFactory.make(path: bad.path, userExtensions: added)
        }
        let content = try BookContentFactory.make(path: good.path, userExtensions: added)
        #expect(try await content.pageCount == 1)
        #expect(try await content.imageData(at: 0) == G64Fixtures.png())
    }

    @Test("標準の画像は確かめない（今どおり 1 ページと答える）")
    func standardImageIsNotChecked() async throws {
        let dir = try G64Fixtures.tempDir("read-std"); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("broken.png")
        try G64Fixtures.noise.write(to: url)
        let content = try BookContentFactory.make(path: url.path, userExtensions: ["foo": .image])
        #expect(try await content.pageCount == 1)
    }

    @Test("標準の cbt と足した tgz はページ数が取れる")
    func tarBooksHavePages() async throws {
        let dir = try G64Fixtures.tempDir("read-tar"); defer { try? FileManager.default.removeItem(at: dir) }
        let cbt = try G64Fixtures.makeTar(at: dir.appendingPathComponent("a.cbt"))
        let tgz = try G64Fixtures.makeTar(at: dir.appendingPathComponent("b.tgz"), gzip: true)
        #expect(try await BookContentFactory.make(path: cbt.path, userExtensions: [:]).pageCount == 3)
        #expect(try await BookContentFactory.make(path: tgz.path, userExtensions: ["tgz": .archive]).pageCount == 3)
    }

    @Test("足した動画・テキストは内蔵では作らない")
    func addedVideoAndTextAreUnsupported() throws {
        let dir = try G64Fixtures.tempDir("read-vt"); defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("a.3gp"); try Data("x".utf8).write(to: video)
        let text = dir.appendingPathComponent("a.docx"); try Data("x".utf8).write(to: text)
        let added: UserExtensionMap = ["3gp": .video, "docx": .text]
        #expect(throws: BookContentError.unsupported(.video)) { _ = try BookContentFactory.make(path: video.path, userExtensions: added) }
        #expect(throws: BookContentError.unsupported(.text)) { _ = try BookContentFactory.make(path: text.path, userExtensions: added) }
    }

    @Test("読めるか: 足した tgz は読める・でたらめなバイト・読めない画像・テキストは読めない")
    func canServePages() async throws {
        let dir = try G64Fixtures.tempDir("read-can"); defer { try? FileManager.default.removeItem(at: dir) }
        let tgz = try G64Fixtures.makeTar(at: dir.appendingPathComponent("ok.tgz"), gzip: true)
        let djvu = dir.appendingPathComponent("x.djvu"); try G64Fixtures.noise.write(to: djvu)
        let img = dir.appendingPathComponent("x.foo"); try G64Fixtures.noise.write(to: img)
        let doc = dir.appendingPathComponent("x.docx"); try Data("x".utf8).write(to: doc)
        let added: UserExtensionMap = ["tgz": .archive, "djvu": .archive, "foo": .image, "docx": .text]
        #expect(await BookReadability.canServePages(path: tgz.path, userExtensions: added))
        #expect(!(await BookReadability.canServePages(path: djvu.path, userExtensions: added)))
        #expect(!(await BookReadability.canServePages(path: img.path, userExtensions: added)))
        #expect(!(await BookReadability.canServePages(path: doc.path, userExtensions: added)))
        #expect(!(await BookReadability.canServePages(path: dir.appendingPathComponent("missing.tgz").path, userExtensions: added)))
    }
}
