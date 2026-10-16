// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G64 Codex fix: macOS の tar が入れる `._名前`（AppleDouble）は、内蔵ビューアのページにならない。
@Suite("G64: tar の AppleDouble は本のページではない")
struct TarAppleDoubleBookContentTests {
    @Test("`._001.jpg` があってもページ数は 2、1 ページ目は 001.jpg")
    func pagesSkipAppleDouble() async throws {
        let dir = try G64Fixtures.tempDir("ad-book"); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let p1 = G64Fixtures.pagePNG(1), p2 = G64Fixtures.pagePNG(2)
        try G64Fixtures.noise.write(to: src.appendingPathComponent("._001.jpg"))
        try p1.write(to: src.appendingPathComponent("001.jpg"))
        try p2.write(to: src.appendingPathComponent("002.jpg"))
        let tar = dir.appendingPathComponent("book.cbt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.environment = ["COPYFILE_DISABLE": "1"]
        p.arguments = ["-cf", tar.path, "-C", src.path, "._001.jpg", "001.jpg", "002.jpg"]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)

        let content = ArchiveBookContent(url: tar)
        #expect(try await content.pageCount == 2)
        #expect(try await content.imageData(at: 0) == p1)
        #expect(try await content.imageData(at: 1) == p2)
    }
}
