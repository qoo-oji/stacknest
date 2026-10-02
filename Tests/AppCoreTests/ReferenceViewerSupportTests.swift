// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G60 v2: 外部ビューアが参照ファイルの型を宣言しているかの判定。一時ディレクトリに偽の .app を作って確かめる。
@Suite("ReferenceViewerSupportTests")
struct ReferenceViewerSupportTests {
    /// `Contents/Info.plist` に `plist` を書いた偽アプリを作る。`plist` が nil なら Info.plist を置かない。
    static func makeApp(plist: Any?, rawData: Data? = nil) throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("G60v2-\(UUID().uuidString).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let url = contents.appendingPathComponent("Info.plist")
        if let rawData {
            try rawData.write(to: url)
        } else if let plist {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: url)
        }
        return app
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    @Test func declaresTheUTType() throws {
        let app = try Self.makeApp(plist: [
            "CFBundleDocumentTypes": [["LSItemContentTypes": ["public.image", BookReference.typeIdentifier]]]
        ])
        defer { Self.remove(app) }
        #expect(appDeclaresBookReferenceSupport(appURL: app))
    }

    @Test func declaresTheExtensionOnly() throws {
        let app = try Self.makeApp(plist: [
            "CFBundleDocumentTypes": [["CFBundleTypeExtensions": ["zip", "stacknestbook"]]]
        ])
        defer { Self.remove(app) }
        #expect(appDeclaresBookReferenceSupport(appURL: app))
    }

    @Test func extensionCheckIsCaseInsensitive() throws {
        let app = try Self.makeApp(plist: [
            "CFBundleDocumentTypes": [["CFBundleTypeExtensions": ["StackNestBook"]]]
        ])
        defer { Self.remove(app) }
        #expect(appDeclaresBookReferenceSupport(appURL: app))
    }

    @Test func declaresNeither() throws {
        let app = try Self.makeApp(plist: [
            "CFBundleDocumentTypes": [
                ["LSItemContentTypes": ["public.image"], "CFBundleTypeExtensions": ["zip", "cbz"]],
                ["CFBundleTypeName": "no types at all"],
            ]
        ])
        defer { Self.remove(app) }
        #expect(!appDeclaresBookReferenceSupport(appURL: app))
    }

    @Test func noInfoPlist() throws {
        let app = try Self.makeApp(plist: nil)
        defer { Self.remove(app) }
        #expect(!appDeclaresBookReferenceSupport(appURL: app))
    }

    @Test func noAppAtAll() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("G60v2-missing-\(UUID().uuidString).app", isDirectory: true)
        #expect(!appDeclaresBookReferenceSupport(appURL: missing))
    }

    @Test func malformedPlist() throws {
        let app = try Self.makeApp(plist: nil, rawData: Data("this is not a plist <<<".utf8))
        defer { Self.remove(app) }
        #expect(!appDeclaresBookReferenceSupport(appURL: app))
    }

    @Test func documentTypesNotAnArray() throws {
        let app = try Self.makeApp(plist: [
            "CFBundleDocumentTypes": ["LSItemContentTypes": [BookReference.typeIdentifier]]
        ])
        defer { Self.remove(app) }
        #expect(!appDeclaresBookReferenceSupport(appURL: app))
    }

    @Test @MainActor func usableViewerNeedsTheDeclaration() throws {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let settings = ViewerSettings(defaults: suite)
        let plain = try Self.makeApp(plist: ["CFBundleDocumentTypes": [["CFBundleTypeExtensions": ["zip"]]]])
        defer { Self.remove(plain) }
        settings.categoryViewerPaths[.archive] = plain.path
        #expect(!HelperLauncher.hasUsableReferenceViewer(category: .archive, settings: settings), "実在するが宣言が無い")
        #expect(!HelperLauncher.hasUsableReferenceViewer(bookPath: "/lib/a.zip", settings: settings))

        let aware = try Self.makeApp(plist: ["CFBundleDocumentTypes": [["LSItemContentTypes": [BookReference.typeIdentifier]]]])
        defer { Self.remove(aware) }
        settings.categoryViewerPaths[.archive] = aware.path
        #expect(HelperLauncher.hasUsableReferenceViewer(category: .archive, settings: settings))
        #expect(HelperLauncher.hasUsableReferenceViewer(bookPath: "/lib/a.zip", settings: settings))
    }
}
