// SPDX-License-Identifier: MIT
import Foundation
import Testing
import LibraryServerAPI
@testable import AppCore

@Suite("G60: 参照ファイルで開くかの判断")
struct ExternalViewerSyncRoutingTests {
    @Test("ローカル: 画像の本・外部ビューア・同期 ON のときだけ参照ファイル",
          arguments: ["/tmp/a.zip", "/tmp/a.cbz", "/tmp/a.rar", "/tmp/a.jpg", "/tmp/a.pdf", "/tmp/a.unknown"])
    func localImageBooks(path: String) {
        #expect(ExternalViewerSyncRouting.localOpensByReference(path: path, useBuiltInImageViewer: false, syncEnabled: true))
        #expect(!ExternalViewerSyncRouting.localOpensByReference(path: path, useBuiltInImageViewer: false, syncEnabled: false))
        #expect(!ExternalViewerSyncRouting.localOpensByReference(path: path, useBuiltInImageViewer: true, syncEnabled: true))
    }

    @Test("ローカル: EPUB・動画・テキスト・パス無しは参照ファイルにしない",
          arguments: ["/tmp/a.epub", "/tmp/a.mp4", "/tmp/a.txt", "/tmp/a.md", ""])
    func localOthers(path: String) {
        #expect(!ExternalViewerSyncRouting.localOpensByReference(path: path, useBuiltInImageViewer: false, syncEnabled: true))
    }

    @Test func remotePrecheck() {
        func may(_ f: String?, builtIn: Bool = false, sync: Bool = true) -> Bool {
            ExternalViewerSyncRouting.remoteMayOpenByReference(filename: f, useBuiltInImageViewer: builtIn, syncEnabled: sync)
        }
        #expect(may("a.zip"))
        #expect(may("a.pdf"))
        #expect(may("a.epub"), "画像の EPUB かどうかは manifest を見てから決める")
        #expect(may(nil), "filename を返さない旧サーバも manifest を見てから決める")
        #expect(!may("a.mp4"))
        #expect(!may("a.txt"))
        #expect(!may("a.zip", builtIn: true))
        #expect(!may("a.zip", sync: false))
    }

    @Test func remoteFinalDecisionNeedsAPageBook() {
        let pages = ManifestDTO(pageCount: 20, direction: "rtl", format: "archive", etag: "e")
        let imageEPUB = ManifestDTO(pageCount: 12, direction: "rtl", format: "text", etag: "e")
        let textEPUB = ManifestDTO(pageCount: 0, direction: "rtl", format: "epub", etag: "e")
        let empty = ManifestDTO(pageCount: 0, direction: "rtl", format: "archive", etag: "e")
        let video = ManifestDTO(pageCount: 1, direction: "rtl", format: "video", etag: "e")
        func opens(_ f: String?, _ m: ManifestDTO, builtIn: Bool = false, sync: Bool = true) -> Bool {
            ExternalViewerSyncRouting.remoteOpensByReference(filename: f, manifest: m,
                                                             useBuiltInImageViewer: builtIn, syncEnabled: sync)
        }
        #expect(opens("a.zip", pages))
        #expect(opens("a.epub", imageEPUB))
        #expect(!opens("a.epub", textEPUB))
        #expect(!opens(nil, textEPUB))
        #expect(!opens("a.zip", empty))
        #expect(!opens(nil, video))
        #expect(!opens("a.zip", pages, builtIn: true))
        #expect(!opens("a.zip", pages, sync: false))
    }
}
