// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite struct BookCategoryTests {
    @Test func classifiesArchiveExtensions() {
        #expect(BookCategory.classify(path: "/tmp/foo.zip") == .archive)
        #expect(BookCategory.classify(path: "/tmp/foo.cbz") == .archive)
        #expect(BookCategory.classify(path: "/tmp/foo.rar") == .archive)
        #expect(BookCategory.classify(path: "/tmp/foo.cbr") == .archive)
        #expect(BookCategory.classify(path: "/tmp/foo.7z") == .archive)
    }

    @Test func classifiesImageExtensions() {
        #expect(BookCategory.classify(path: "/tmp/foo.jpg") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.jpeg") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.png") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.gif") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.webp") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.heic") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.heif") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.bmp") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.tiff") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.tif") == .image)
    }

    @Test func classifiesVideoExtensions() {
        #expect(BookCategory.classify(path: "/tmp/foo.mp4") == .video)
        #expect(BookCategory.classify(path: "/tmp/foo.mov") == .video)
        #expect(BookCategory.classify(path: "/tmp/foo.avi") == .video)
        #expect(BookCategory.classify(path: "/tmp/foo.mkv") == .video)
        #expect(BookCategory.classify(path: "/tmp/foo.webm") == .video)
        #expect(BookCategory.classify(path: "/tmp/foo.m4v") == .video)
    }

    @Test func classifiesTextExtensions() {
        #expect(BookCategory.classify(path: "/tmp/foo.pdf") == .text)
        #expect(BookCategory.classify(path: "/tmp/foo.epub") == .text)
        #expect(BookCategory.classify(path: "/tmp/foo.txt") == .text)
        #expect(BookCategory.classify(path: "/tmp/foo.md") == .text)
        #expect(BookCategory.classify(path: "/tmp/foo.rtf") == .text)
    }

    @Test func classifiesUppercaseExtensions() {
        #expect(BookCategory.classify(path: "/tmp/foo.JPG") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.MP4") == .video)
        #expect(BookCategory.classify(path: "/tmp/foo.ZIP") == .archive)
        #expect(BookCategory.classify(path: "/tmp/foo.PDF") == .text)
    }

    @Test func classifiesUnknownExtensionAsArchiveFallback() {
        #expect(BookCategory.classify(path: "/tmp/foo.xyz") == .archive)
        #expect(BookCategory.classify(path: "/tmp/noext") == .archive)
    }

    @Test func classifiesExistingDirectoryAsFolder() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "BookCategoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        #expect(BookCategory.classify(path: tempDir.path(percentEncoded: false)) == .folder)
    }

    @Test func displayNameAndHintAreNonEmpty() {
        for category in BookCategory.allCases {
            #expect(!category.displayName.isEmpty)
            #expect(!category.extensionsHint.isEmpty)
        }
    }

    @Test func builtInViewerSupportClassifiesByExtension() {
        #expect(BookCategory.builtInViewerSupport(filename: "a.mp4") == .unsupportedVideo)
        #expect(BookCategory.builtInViewerSupport(filename: "a.MOV") == .unsupportedVideo)
        #expect(BookCategory.builtInViewerSupport(filename: "a.mkv") == .unsupportedVideo)
        #expect(BookCategory.builtInViewerSupport(filename: "a.epub") == .supported)   // G48-2: epub は内蔵ビューア対応
        #expect(BookCategory.builtInViewerSupport(filename: "a.txt") == .unsupportedDocument)
        #expect(BookCategory.builtInViewerSupport(filename: "a.md") == .unsupportedDocument)
        #expect(BookCategory.builtInViewerSupport(filename: "a.rtf") == .unsupportedDocument)
        #expect(BookCategory.builtInViewerSupport(filename: "a.pdf") == .supported)   // pdf は対応
        #expect(BookCategory.builtInViewerSupport(filename: "a.cbz") == .supported)
        #expect(BookCategory.builtInViewerSupport(filename: "a.zip") == .supported)
        #expect(BookCategory.builtInViewerSupport(filename: "a.jpg") == .supported)
        #expect(BookCategory.builtInViewerSupport(filename: "a.unknownext") == .supported)   // 未知=archive 倒し
    }

    // MARK: - G64: 標準の表と足した拡張子

    @Test func presetTableHas29ExtensionsIncludingTar() {
        #expect(BookCategory.presetCategories.count == 29)
        #expect(BookCategory.presetCategories["cbt"] == .archive)
        #expect(BookCategory.presetCategories["tar"] == .archive)
        #expect(Set(BookCategory.presetCategories.keys) == BookCategory.supportedExtensions)
        #expect(BookCategory.classify(path: "/tmp/foo.cbt", userExtensions: [:]) == .archive)
        #expect(BookCategory.classify(path: "/tmp/foo.TAR", userExtensions: [:]) == .archive)
        #expect(BookCategory.classify(path: "/tmp/foo.CBT", userExtensions: [:]) == .archive)
        #expect(BookCategory.archive.extensionsHint == ".zip / .cbz / .rar / .cbr / .7z / .cbt / .tar")
    }

    @Test func classifiesAddedExtensionsIntoTheChosenCategory() {
        let added: UserExtensionMap = ["tgz": .archive, "avif": .image, "3gp": .video, "docx": .text]
        #expect(BookCategory.classify(path: "/tmp/a.tgz", userExtensions: added) == .archive)
        #expect(BookCategory.classify(path: "/tmp/a.AVIF", userExtensions: added) == .image)
        #expect(BookCategory.classify(path: "/tmp/a.3gp", userExtensions: added) == .video)
        #expect(BookCategory.classify(path: "/tmp/a.Docx", userExtensions: added) == .text)
        // 足していない拡張子は今どおりアーカイブ。
        #expect(BookCategory.classify(path: "/tmp/a.djvu", userExtensions: added) == .archive)
        #expect(BookCategory.classify(path: "/tmp/noext", userExtensions: added) == .archive)
    }

    @Test func presetAlwaysWinsOverTheAddedList() {
        // 一覧に標準と重なる項目が紛れても（読み込みで落とすが、渡す値は呼び出し側が作れる）標準が勝つ。
        let added: UserExtensionMap = ["zip": .text, "cbt": .text, "jpg": .video, "epub": .archive]
        #expect(BookCategory.classify(path: "/tmp/a.zip", userExtensions: added) == .archive)
        #expect(BookCategory.classify(path: "/tmp/a.cbt", userExtensions: added) == .archive)
        #expect(BookCategory.classify(path: "/tmp/a.jpg", userExtensions: added) == .image)
        #expect(BookCategory.classify(path: "/tmp/a.epub", userExtensions: added) == .text)
        #expect(BookCategory.userCategory(path: "/tmp/a.zip", userExtensions: added) == nil)
    }

    @Test func folderInTheListIsIgnored() {
        #expect(BookCategory.classify(path: "/tmp/a.dir", userExtensions: ["dir": .folder]) == .archive)
        #expect(BookCategory.userCategory(path: "/tmp/a.dir", userExtensions: ["dir": .folder]) == nil)
    }

    @Test func directoryIsAFolderEvenWithAnAddedExtension() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "G64-\(UUID().uuidString).tgz")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.path(percentEncoded: false)
        #expect(BookCategory.classify(path: path, userExtensions: ["tgz": .archive]) == .folder)
        #expect(BookCategory.userCategory(path: path, userExtensions: ["tgz": .archive]) == nil)
    }

    @Test func userCategoryIsOnlyForAddedExtensions() {
        let added: UserExtensionMap = ["tgz": .archive, "docx": .text]
        #expect(BookCategory.userCategory(path: "/tmp/a.TGZ", userExtensions: added) == .archive)
        #expect(BookCategory.userCategory(path: "/tmp/a.docx", userExtensions: added) == .text)
        #expect(BookCategory.userCategory(path: "/tmp/a.djvu", userExtensions: added) == nil, "足していない")
        #expect(BookCategory.userCategory(path: "/tmp/a.cbt", userExtensions: added) == nil, "標準")
        #expect(BookCategory.userCategory(path: "/tmp/a.tgz", userExtensions: [:]) == nil)
    }

    @Test func registrableExtensionsArePresetPlusAdded() {
        #expect(BookCategory.registrableExtensions(userExtensions: [:]) == BookCategory.supportedExtensions)
        let r = BookCategory.registrableExtensions(userExtensions: ["tgz": .archive, "docx": .text])
        #expect(r.count == 31)
        #expect(r.contains("tgz") && r.contains("docx") && r.contains("cbt") && r.contains("tar"))
        #expect(!r.contains("djvu"))
    }

    /// `builtInViewerSupport` はリモートの本の filename 用で、標準の表だけで決める（手元の一覧を見ない）。
    @Test func builtInViewerSupportIgnoresTheLocalList() {
        #expect(BookCategory.builtInViewerSupport(filename: "a.cbt") == .supported)
        #expect(BookCategory.builtInViewerSupport(filename: "a.TAR") == .supported)
        // 引数に一覧が無い＝足した拡張子（サーバでは動画やテキストかもしれない）は未知として通す。
        #expect(BookCategory.builtInViewerSupport(filename: "a.ogv") == .supported)
        #expect(BookCategory.builtInViewerSupport(filename: "a.docx") == .supported)
    }
}
