// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G64: 足した拡張子の本の表紙の順（spec §6.6）。1. StackNest が読む → 2. Quick Look（偽物）。
/// 標準と未知の拡張子では Quick Look を呼ばない。
@Suite("G64: 足した拡張子の本の表紙")
struct UserExtensionCoverTests {
    private func extract(_ url: URL, _ added: UserExtensionMap, _ fake: FakeThumbnailer,
                         preferredName: String? = nil) async throws -> Data {
        try await CoverRefresher.extractCoverData(sourceURL: url, preferredName: preferredName,
                                                  userExtensions: added, thumbnailer: fake)
    }

    @Test("足したアーカイブ: 先頭の画像（Quick Look は呼ばない）")
    func addedArchiveUsesTheFirstImage() async throws {
        let dir = try G64Fixtures.tempDir("cov-arc"); defer { try? FileManager.default.removeItem(at: dir) }
        let tgz = try G64Fixtures.makeTar(at: dir.appendingPathComponent("a.tgz"), gzip: true)
        let fake = FakeThumbnailer()
        #expect(try await extract(tgz, ["tgz": .archive], fake) == G64Fixtures.pagePNG(1))
        #expect(fake.calls.isEmpty)
    }

    @Test("足したアーカイブ: 名前なしは page1・名前指定はその画像・@ 始まりは無視して page1")
    func addedArchiveHonoursPreferredName() async throws {
        let dir = try G64Fixtures.tempDir("cov-name"); defer { try? FileManager.default.removeItem(at: dir) }
        let tgz = try G64Fixtures.makeTar(at: dir.appendingPathComponent("a.tgz"), gzip: true)
        let fake = FakeThumbnailer()
        let added: UserExtensionMap = ["tgz": .archive]
        #expect(try await extract(tgz, added, fake) == G64Fixtures.pagePNG(1))
        #expect(try await extract(tgz, added, fake, preferredName: "page3.png") == G64Fixtures.pagePNG(3))
        #expect(try await extract(tgz, added, fake, preferredName: "@t=1.0") == G64Fixtures.pagePNG(1))
        #expect(fake.calls.isEmpty)
    }

    @Test("足したアーカイブ: 画像が無ければ中の PDF の 1 ページ目")
    func addedArchiveFallsBackToTheEmbeddedPDF() async throws {
        let dir = try G64Fixtures.tempDir("cov-pdf"); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try G64Fixtures.copyPDFOnlyZip(to: dir.appendingPathComponent("pdf-only.foo"))
        let fake = FakeThumbnailer()
        let data = try await extract(url, ["foo": .archive], fake)
        #expect(G64Fixtures.isJPEG(data))
        #expect(data != FakeThumbnailer.marker)
        #expect(fake.calls.isEmpty)
    }

    @Test("足したアーカイブ: 読めなければ（投げても）Quick Look")
    func unreadableAddedArchiveFallsBackToQuickLook() async throws {
        let dir = try G64Fixtures.tempDir("cov-djvu"); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.djvu"); try G64Fixtures.noise.write(to: url)
        let fake = FakeThumbnailer()
        #expect(try await extract(url, ["djvu": .archive], fake) == FakeThumbnailer.marker)
        #expect(fake.calls == [url])
    }

    @Test("足した画像: 小さくても JPEG に書き直す・読めなければ Quick Look")
    func addedImageIsReencodedOrFallsBack() async throws {
        let dir = try G64Fixtures.tempDir("cov-img"); defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("a.foo"); try G64Fixtures.png().write(to: good)
        let bad = dir.appendingPathComponent("b.foo"); try G64Fixtures.noise.write(to: bad)
        let fake = FakeThumbnailer()
        let data = try await extract(good, ["foo": .image], fake)
        #expect(G64Fixtures.isJPEG(data) && data != FakeThumbnailer.marker)
        #expect(fake.calls.isEmpty)
        #expect(try await extract(bad, ["foo": .image], fake) == FakeThumbnailer.marker)
        #expect(fake.calls == [bad])
    }

    @Test("足した動画: AVFoundation を先に（拡張子の制限は外す）・開けなければ Quick Look")
    func addedVideoTriesAVFoundationFirst() async throws {
        let dir = try G64Fixtures.tempDir("cov-vid"); defer { try? FileManager.default.removeItem(at: dir) }
        let video = try G64Fixtures.copySampleVideo(to: dir.appendingPathComponent("a.3gp"))
        let junk = dir.appendingPathComponent("b.3gp"); try G64Fixtures.noise.write(to: junk)
        let fake = FakeThumbnailer()
        let data = try await extract(video, ["3gp": .video], fake)
        #expect(G64Fixtures.isJPEG(data) && data != FakeThumbnailer.marker)
        #expect(fake.calls.isEmpty)
        #expect(try await extract(junk, ["3gp": .video], fake) == FakeThumbnailer.marker)
        #expect(fake.calls == [junk])
    }

    @Test("足したテキスト: 最初から Quick Look・Quick Look も駄目なら unsupportedFormat")
    func addedTextUsesQuickLookOnly() async throws {
        let dir = try G64Fixtures.tempDir("cov-txt"); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = dir.appendingPathComponent("a.docx"); try Data("x".utf8).write(to: doc)
        let fake = FakeThumbnailer()
        #expect(try await extract(doc, ["docx": .text], fake) == FakeThumbnailer.marker)
        let failing = FakeThumbnailer(result: nil)
        await #expect(throws: CoverRefreshError.unsupportedFormat) {
            _ = try await extract(doc, ["docx": .text], failing)
        }
        #expect(failing.calls == [doc])
    }

    @Test("標準の cbt の作り直しは先頭の画像・標準と未知の拡張子では Quick Look を呼ばない")
    func standardAndUnknownNeverUseQuickLook() async throws {
        let dir = try G64Fixtures.tempDir("cov-std"); defer { try? FileManager.default.removeItem(at: dir) }
        let cbt = try G64Fixtures.makeTar(at: dir.appendingPathComponent("a.cbt"))
        let txt = dir.appendingPathComponent("a.txt"); try Data("x".utf8).write(to: txt)
        let djvu = dir.appendingPathComponent("a.djvu"); try G64Fixtures.noise.write(to: djvu)
        let fake = FakeThumbnailer()
        #expect(try await extract(cbt, [:], fake) == G64Fixtures.png())
        await #expect(throws: CoverRefreshError.unsupportedFormat) { _ = try await extract(txt, [:], fake) }
        await #expect(throws: CoverRefreshError.unsupportedFormat) { _ = try await extract(djvu, [:], fake) }
        #expect(fake.calls.isEmpty)
    }
}
