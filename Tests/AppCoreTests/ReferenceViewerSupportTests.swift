// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G60 v2: 外部ビューアが参照ファイルの型を宣言しているかの判定。一時ディレクトリに偽の .app を作って確かめる。
@Suite("ReferenceViewerSupportTests")
struct ReferenceViewerSupportTests {
    /// `Contents/Info.plist` に `plist` を書いた偽アプリを作る。`plist` が nil なら Info.plist を置かない。
    static func makeApp(plist: Any?, rawData: Data? = nil, format: PropertyListSerialization.PropertyListFormat = .xml) throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("G60v2-\(UUID().uuidString).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let url = contents.appendingPathComponent("Info.plist")
        if let rawData {
            try rawData.write(to: url)
        } else if let plist {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
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

    @Test func binaryPlistDeclaringTheType() throws {
        let app = try Self.makeApp(plist: [
            "CFBundleDocumentTypes": [["LSItemContentTypes": [BookReference.typeIdentifier]]]
        ], format: .binary)
        defer { Self.remove(app) }
        let head = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")).prefix(6)
        #expect(head == Data("bplist".utf8), "fixture is really binary")
        #expect(appDeclaresBookReferenceSupport(appURL: app))
    }

    @Test func utTypeMatchIsCaseInsensitive() throws {
        let app = try Self.makeApp(plist: [
            "CFBundleDocumentTypes": [["LSItemContentTypes": ["App.Shelfsmith.StackNest.Book-Reference"]]]
        ])
        defer { Self.remove(app) }
        #expect(appDeclaresBookReferenceSupport(appURL: app))
    }

    @Test func noDocumentTypesKey() throws {
        let app = try Self.makeApp(plist: ["CFBundleName": "Viewer"])
        defer { Self.remove(app) }
        #expect(!appDeclaresBookReferenceSupport(appURL: app))
    }

    @Test func nonDictionaryEntriesAreSkipped() throws {
        let valid: [String: Any] = ["CFBundleTypeExtensions": ["stacknestbook"]]
        let mixed = try Self.makeApp(plist: ["CFBundleDocumentTypes": ["junk", 3, valid] as [Any]])
        defer { Self.remove(mixed) }
        #expect(appDeclaresBookReferenceSupport(appURL: mixed))
        let junkOnly = try Self.makeApp(plist: ["CFBundleDocumentTypes": ["junk", 3, ["x"]] as [Any]])
        defer { Self.remove(junkOnly) }
        #expect(!appDeclaresBookReferenceSupport(appURL: junkOnly))
    }

    /// 「何でも開ける」宣言（`*`）や一般的な型（`public.json` など）は、この型を理解している証拠ではない。
    @Test func wildcardAndGenericTypesDoNotCount() throws {
        let app = try Self.makeApp(plist: [
            "CFBundleDocumentTypes": [
                ["CFBundleTypeExtensions": ["*"]],
                ["LSItemContentTypes": ["public.json", "public.data", "public.item"]],
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
