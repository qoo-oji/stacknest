// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

@Suite("G54-S2: 形式 → どちらのビューア設定に従うか")
struct ViewerChoiceTests {
    @Test("アーカイブ・画像・PDF は画像側に従う", arguments: [
        "/tmp/a.zip", "/tmp/a.cbz", "/tmp/a.rar", "/tmp/a.cbr", "/tmp/a.7z", "/tmp/a.cb7",
        "/tmp/a.jpg", "/tmp/a.png", "/tmp/a.webp", "/tmp/a.heic", "/tmp/a.pdf",
    ])
    func imageSide(path: String) {
        #expect(ViewerChoice.viewerSwitch(forPath: path) == .image)
    }

    @Test("EPUB は EPUB 側に従う")
    func epubSide() {
        #expect(ViewerChoice.viewerSwitch(forPath: "/tmp/a.epub") == .epub)
        #expect(ViewerChoice.viewerSwitch(forPath: "/tmp/A.EPUB") == .epub)
    }

    @Test("動画とテキストは設定に関わらず外部", arguments: [
        "/tmp/a.mp4", "/tmp/a.mov", "/tmp/a.avi", "/tmp/a.mkv", "/tmp/a.webm", "/tmp/a.m4v",
        "/tmp/a.txt", "/tmp/a.md", "/tmp/a.rtf",
    ])
    func externalOnly(path: String) {
        #expect(ViewerChoice.viewerSwitch(forPath: path) == .externalOnly)
    }

    @Test("未知の拡張子はアーカイブ扱いなので画像側")
    func unknownExtension() {
        #expect(ViewerChoice.viewerSwitch(forPath: "/tmp/a.unknownext") == .image)
    }

    @Test("ディレクトリはフォルダ本なので画像側")
    func directory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("g54s2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ViewerChoice.viewerSwitch(forPath: dir.path) == .image)
    }

    @Test("G54-S2: 2 つの設定の組み合わせで内蔵を試すかが決まる")
    @MainActor
    func shouldTryBuiltInAcrossCombinations() {
        let suite = UserDefaults(suiteName: "g54s2-choice-\(UUID().uuidString)")!
        let s = ViewerSettings(defaults: suite)

        for (image, epub) in [(true, true), (true, false), (false, true), (false, false)] {
            s.useBuiltInImageViewer = image
            s.useBuiltInEPUBViewer = epub
            #expect(ViewerChoice.shouldTryBuiltIn(forPath: "/tmp/a.zip", settings: s) == image)
            #expect(ViewerChoice.shouldTryBuiltIn(forPath: "/tmp/a.pdf", settings: s) == image)
            #expect(ViewerChoice.shouldTryBuiltIn(forPath: "/tmp/a.epub", settings: s) == epub)
            #expect(ViewerChoice.shouldTryBuiltIn(forPath: "/tmp/a.mp4", settings: s) == false)
            #expect(ViewerChoice.shouldTryBuiltIn(forPath: "/tmp/a.txt", settings: s) == false)
        }
    }

    // MARK: - G64: 足した拡張子は選んだ種類のとおり

    @Test("G64: 足した動画・テキストは外部、足したアーカイブ・画像と標準の tar は画像側")
    func addedExtensionsFollowTheirCategory() {
        let added: UserExtensionMap = ["tgz": .archive, "avif": .image, "3gp": .video, "docx": .text]
        #expect(ViewerChoice.viewerSwitch(forPath: "/tmp/a.3gp", userExtensions: added) == .externalOnly)
        #expect(ViewerChoice.viewerSwitch(forPath: "/tmp/a.docx", userExtensions: added) == .externalOnly)
        #expect(ViewerChoice.viewerSwitch(forPath: "/tmp/a.tgz", userExtensions: added) == .image)
        #expect(ViewerChoice.viewerSwitch(forPath: "/tmp/a.avif", userExtensions: added) == .image)
        #expect(ViewerChoice.viewerSwitch(forPath: "/tmp/a.cbt", userExtensions: [:]) == .image)
        #expect(ViewerChoice.viewerSwitch(forPath: "/tmp/a.tar", userExtensions: [:]) == .image)
        // 足していなければ今どおり未知＝アーカイブ＝画像側。
        #expect(ViewerChoice.viewerSwitch(forPath: "/tmp/a.3gp", userExtensions: [:]) == .image)
    }
}
