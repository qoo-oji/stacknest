// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G60 v3: 対応ビューアの宣言（`StackNestViewerSupport`）の読み取りと版の選び方。
/// 一時ディレクトリに偽の .app を作って確かめる（名前の既定を試せるよう、毎回別の親ディレクトリに置く）。
@Suite("G60 v3: 対応ビューアの宣言（StackNestViewerSupport）")
struct ReferenceViewerSupportTests {
    /// `Contents/Info.plist` に `plist`（または `rawData`）を書いた偽アプリを作る。どちらも nil なら Info.plist を置かない。
    static func makeApp(plist: Any?, rawData: Data? = nil,
                        format: PropertyListSerialization.PropertyListFormat = .xml,
                        name: String = "ExampleViewer") throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("G60v3-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let url = contents.appendingPathComponent("Info.plist")
        if let rawData {
            try rawData.write(to: url)
        } else if let plist {
            try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0).write(to: url)
        }
        return app
    }

    static func remove(_ app: URL) { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

    /// 宣言の辞書。`versions` はそのまま `referenceFormatVersions` に入れる（形の崩れも試せるよう Any）。
    static func declaring(_ versions: Any, extra: [String: Any] = [:]) -> [String: Any] {
        var plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.viewer",
            "CFBundleName": "Example Viewer",
            ViewerSupportDeclaration.infoPlistKey: [ViewerSupportDeclaration.versionsKey: versions],
        ]
        for (key, value) in extra { plist[key] = value }
        return plist
    }

    @Test func declaresVersionOne() throws {
        let app = try Self.makeApp(plist: Self.declaring([1])); defer { Self.remove(app) }
        let declaration = try #require(ViewerSupportDeclaration.read(appURL: app))
        #expect(declaration.bundleIdentifier == "com.example.viewer")
        #expect(declaration.displayName == "Example Viewer")
        #expect(declaration.referenceFormatVersions == [1])
        #expect(declaration.chosenFormatVersion == 1)
        let viewer = try #require(ReferenceViewer.resolve(appURL: app))
        #expect(viewer.formatVersion == 1)
        #expect(viewer.appURL == app)
        #expect(viewer.declaration == declaration)
    }

    @Test func choosesTheHighestCommonVersion() {
        #expect(ViewerSupportDeclaration.chooseVersion(declared: [1, 2, 3], writable: [1, 2]) == 2)
        #expect(ViewerSupportDeclaration.chooseVersion(declared: [3, 1], writable: [1, 2, 3]) == 3)
        #expect(ViewerSupportDeclaration.chooseVersion(declared: [1], writable: [1, 2]) == 1)
        #expect(ViewerSupportDeclaration.chooseVersion(declared: [2], writable: [1]) == nil)
        #expect(ViewerSupportDeclaration.chooseVersion(declared: [], writable: [1]) == nil)
    }

    /// 今の StackNest が書けるのは版 1 だけ。将来の版を併せて宣言していても 1 で書き、1 が無ければ未対応。
    @Test func stackNestWritesVersionOne() throws {
        #expect(BookReference.writableVersions == [1])
        let app = try Self.makeApp(plist: Self.declaring([1, 2])); defer { Self.remove(app) }
        #expect(ReferenceViewer.resolve(appURL: app)?.formatVersion == 1)
        let future = try Self.makeApp(plist: Self.declaring([2, 3])); defer { Self.remove(future) }
        #expect(ReferenceViewer.resolve(appURL: future) == nil, "共通の版が無ければ未対応")
        #expect(ViewerSupportDeclaration.read(appURL: future)?.referenceFormatVersions == [2, 3])
    }

    /// `<true/>` と `<real>1</real>` は NSNumber として Int の 1 に橋渡しされる（手元で確認済み）。
    /// 正の `<integer>` だけを数える。XML をそのまま書いて形を固定する。
    @Test func nonIntegerElementsAreIgnored() throws {
        func plistXML(_ elements: String) -> Data {
            Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>CFBundleIdentifier</key><string>com.example.viewer</string>
              <key>StackNestViewerSupport</key><dict>
                <key>referenceFormatVersions</key><array>\(elements)</array>
              </dict>
            </dict></plist>
            """.utf8)
        }
        let mixed = try Self.makeApp(plist: nil, rawData: plistXML(
            "<true/><real>1</real><real>1.5</real><string>1</string><integer>0</integer><integer>-1</integer><array/><integer>1</integer>"))
        defer { Self.remove(mixed) }
        #expect(ViewerSupportDeclaration.read(appURL: mixed)?.referenceFormatVersions == [1])
        #expect(ReferenceViewer.resolve(appURL: mixed)?.formatVersion == 1)

        let junk = try Self.makeApp(plist: nil, rawData: plistXML(
            "<true/><real>1</real><string>1</string><integer>0</integer>"))
        defer { Self.remove(junk) }
        #expect(ViewerSupportDeclaration.read(appURL: junk)?.referenceFormatVersions == [])
        #expect(ReferenceViewer.resolve(appURL: junk) == nil)
    }

    /// キーが無い・形が違うときは未対応。それでも名前と bundle id は読める（設定の「未対応」の表示に使う）。
    @Test func missingOrMisshapenKeyIsUnsupported() throws {
        let shapes: [[String: Any]] = [
            ["CFBundleIdentifier": "com.example.viewer"],
            ["CFBundleIdentifier": "com.example.viewer", ViewerSupportDeclaration.infoPlistKey: [1]],
            ["CFBundleIdentifier": "com.example.viewer", ViewerSupportDeclaration.infoPlistKey: [String: Any]()],
            Self.declaring(1),
            Self.declaring("1"),
        ]
        for shape in shapes {
            let app = try Self.makeApp(plist: shape); defer { Self.remove(app) }
            let declaration = try #require(ViewerSupportDeclaration.read(appURL: app))
            #expect(declaration.referenceFormatVersions.isEmpty)
            #expect(declaration.chosenFormatVersion == nil)
            #expect(declaration.bundleIdentifier == "com.example.viewer")
            #expect(ReferenceViewer.resolve(appURL: app) == nil)
        }
    }

    /// v2 の判定（参照ファイルの型・拡張子の宣言）は、もう対応の根拠にならない。`*` や `public.json` も同じ。
    @Test func typeDeclarationAloneIsNotSupport() throws {
        let app = try Self.makeApp(plist: [
            "CFBundleIdentifier": "com.example.viewer",
            "CFBundleDocumentTypes": [
                ["LSItemContentTypes": [BookReference.typeIdentifier]],
                ["CFBundleTypeExtensions": [BookReference.fileExtension, "*"]],
                ["LSItemContentTypes": ["public.json", "public.data"]],
            ],
        ])
        defer { Self.remove(app) }
        #expect(ViewerSupportDeclaration.read(appURL: app)?.referenceFormatVersions == [])
        #expect(ReferenceViewer.resolve(appURL: app) == nil)
    }

    @Test func binaryPlistWorks() throws {
        let app = try Self.makeApp(plist: Self.declaring([1]), format: .binary); defer { Self.remove(app) }
        let head = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")).prefix(6)
        #expect(head == Data("bplist".utf8), "fixture is really binary")
        #expect(ReferenceViewer.resolve(appURL: app)?.formatVersion == 1)
    }

    /// キャッシュしない: 同じパスの Info.plist を書き換えたら、次の読みで結果が変わる。
    @Test func rereadsAfterThePlistChanges() throws {
        let app = try Self.makeApp(plist: ["CFBundleIdentifier": "com.example.viewer"]); defer { Self.remove(app) }
        #expect(ReferenceViewer.resolve(appURL: app) == nil)
        try PropertyListSerialization.data(fromPropertyList: Self.declaring([1]), format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(ReferenceViewer.resolve(appURL: app)?.formatVersion == 1)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.viewer"],
                                           format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(ReferenceViewer.resolve(appURL: app) == nil)
    }

    /// 名前は CFBundleDisplayName → CFBundleName → `.app` を除いたファイル名。空白だけの値は使わない。
    @Test func displayNameFallsBack() throws {
        let display = try Self.makeApp(plist: Self.declaring([1], extra: ["CFBundleDisplayName": "表示名"]))
        defer { Self.remove(display) }
        #expect(ViewerSupportDeclaration.read(appURL: display)?.displayName == "表示名")

        let blank = try Self.makeApp(plist: Self.declaring([1], extra: ["CFBundleDisplayName": "  "]))
        defer { Self.remove(blank) }
        #expect(ViewerSupportDeclaration.read(appURL: blank)?.displayName == "Example Viewer")

        let fileOnly = try Self.makeApp(
            plist: [ViewerSupportDeclaration.infoPlistKey: [ViewerSupportDeclaration.versionsKey: [1]]],
            name: "FileNamed")
        defer { Self.remove(fileOnly) }
        let declaration = try #require(ViewerSupportDeclaration.read(appURL: fileOnly))
        #expect(declaration.displayName == "FileNamed")
        #expect(declaration.bundleIdentifier == nil)
        #expect(ReferenceViewer.resolve(appURL: fileOnly)?.formatVersion == 1, "bundle id が無くても宣言は効く")
    }

    @Test func unreadablePlistIsNil() throws {
        let none = try Self.makeApp(plist: nil); defer { Self.remove(none) }
        #expect(ViewerSupportDeclaration.read(appURL: none) == nil)
        let broken = try Self.makeApp(plist: nil, rawData: Data("this is not a plist <<<".utf8))
        defer { Self.remove(broken) }
        #expect(ViewerSupportDeclaration.read(appURL: broken) == nil)
        let notADictionary = try Self.makeApp(plist: ["a", "b"]); defer { Self.remove(notADictionary) }
        #expect(ViewerSupportDeclaration.read(appURL: notADictionary) == nil)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("G60v3-missing-\(UUID().uuidString).app", isDirectory: true)
        #expect(ViewerSupportDeclaration.read(appURL: missing) == nil)
        #expect(ReferenceViewer.resolve(appURL: missing) == nil)
    }

    @Test @MainActor func referenceViewerNeedsTheKey() throws {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let settings = ViewerSettings(defaults: suite)
        let typeOnly = try Self.makeApp(plist: [
            "CFBundleDocumentTypes": [["LSItemContentTypes": [BookReference.typeIdentifier]]]
        ])
        defer { Self.remove(typeOnly) }
        settings.categoryViewerPaths[.archive] = typeOnly.path
        #expect(HelperLauncher.referenceViewer(category: .archive, settings: settings) == nil, "型だけの宣言では渡さない")
        #expect(HelperLauncher.referenceViewer(bookPath: "/lib/a.zip", settings: settings) == nil)

        let declared = try Self.makeApp(plist: Self.declaring([1])); defer { Self.remove(declared) }
        settings.categoryViewerPaths[.archive] = declared.path
        let viewer = try #require(HelperLauncher.referenceViewer(category: .archive, settings: settings))
        #expect(viewer.appURL.path == declared.path)
        #expect(viewer.formatVersion == 1)
        #expect(HelperLauncher.referenceViewer(bookPath: "/lib/a.zip", settings: settings)?.appURL.path == declared.path)
    }
}
