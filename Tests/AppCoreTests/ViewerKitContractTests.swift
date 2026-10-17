// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

/// G63 段 4（spec §11.2 の契約の試験）: StackNest（作る側・受ける側）と StackNestViewerKit（読む側の部品）の約束が
/// 食い違わないことを、StackNest の側で確かめる。置き換えの前（G60 のコード）から緑で、置き換えの後も緑のまま。
@Suite("G63: 部品との契約")
struct ViewerKitContractTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func freshDefaults() -> (UserDefaults, () -> Void) {
        let name = "g63-contract-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    /// ⑤ StackNest が書ける版は、すべて部品が読める（宣言から選んだ版で、部品の型がいつも作れる）。
    @Test func everyWritableVersionIsReadableByTheKit() {
        #expect(!BookReferences.writableVersions.isEmpty)
        #expect(Set(BookReferences.writableVersions).isSubset(of: StackNestFormat.supportedVersions))
    }

    /// StackNest が書き出す型の宣言（`App/StackNest/Info.plist` の `UTExportedTypeDeclarations`）が部品の定数と同じ。
    @Test func exportedReferenceTypeMatchesTheKit() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/StackNest/Info.plist")
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        let exported = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let entry = try #require(exported.first { $0["UTTypeIdentifier"] as? String == StackNestFormat.typeIdentifier })
        let tags = try #require(entry["UTTypeTagSpecification"] as? [String: Any])
        #expect(tags["public.filename-extension"] as? [String] == [StackNestFormat.fileExtension])
        #expect(entry["UTTypeConformsTo"] as? [String] == ["public.json"])
    }

    /// ④ 部品が組んだ名乗り（`kit=` 付き・`_`・`+` を含む bundle id・64 文字を超える版）と、部品より前のフォークの
    /// 名乗り（`kit=` なし）が、確認できた対応ビューアの記録で同じ bundle id・版・`format=` になる。
    @Test func kitAndPreKitHeadersRecordTheSameViewer() throws {
        let kitMade = StackNestViewerIdentification(
            bundleIdentifier: "com.example.my_viewer+beta", version: String(repeating: "9", count: 80), format: 1
        ).headerValue
        #expect(kitMade.hasSuffix("; format=1; kit=\(StackNestViewerKitInfo.version)"))
        let nines = String(repeating: "9", count: 64)
        let preKit = "com.example.my_viewer+beta/\(nines); format=1"
        let expected = ConfirmedViewer(bundleIdentifier: "com.example.my_viewer+beta", viewerVersion: nines,
                                       formatVersion: 1, confirmedAt: t0)
        for header in [kitMade, preKit] {
            let (defaults, done) = freshDefaults()
            defer { done() }
            let saved = ConfirmedViewerStore(defaults: defaults).record(appBundleIdentifier: nil, viewer: header, at: t0)
            #expect(saved == expected, "\(header)")
        }
    }

    /// 名乗りの形でない値・名乗り無しは、今までどおり渡した先のアプリの bundle id で、版なしで記録する。
    @Test func unparseableHeadersRecordWithoutAVersion() {
        let expected = ConfirmedViewer(bundleIdentifier: "com.example.app", viewerVersion: nil, formatVersion: nil,
                                       confirmedAt: t0)
        for header in ["not a viewer header", "com.example.viewer!/1.0; format=1", nil] as [String?] {
            let (defaults, done) = freshDefaults()
            defer { done() }
            let saved = ConfirmedViewerStore(defaults: defaults)
                .record(appBundleIdentifier: "com.example.app", viewer: header, at: t0)
            #expect(saved == expected, "\(header ?? "nil")")
        }
    }

    /// 部品のモジュールを直接 import するのは `Sources/AppCore/` だけ（ほかは AppCore の再輸出で使う。依存は
    /// Package.swift の AppCore にだけ書き、App/project.yml には足さないため）。`Tests/EPUBAdapterTests/ImportBoundaryTests`
    /// の Washi の境界と同じ形。
    @Test func kitImportIsConfinedToAppCore() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let excludedDirNames: Set<String> = ["build", ".build", "DerivedData", ".git"]
        // 属性（`@_exported`・`@testable`・`@preconcurrency` など）・アクセスレベル（`public import` など）・
        // 宣言の種類を付けた import（`import struct StackNestViewerKitCore.X`）も拾う。
        let pattern = try NSRegularExpression(pattern: #"^\s*(@\w+(\([^)]*\))?\s+)*((public|package|internal|fileprivate|private)\s+)?import\s+((typealias|struct|class|enum|protocol|actor|let|var|func)\s+)?StackNestViewerKit\w*\b"#)
        let fm = FileManager.default
        var offenders: [String] = []
        for scanRoot in ["Sources", "App", "Tests"].map({ root.appendingPathComponent($0) }) {
            guard let e = fm.enumerator(at: scanRoot, includingPropertiesForKeys: [.isDirectoryKey]) else {
                Issue.record("ディレクトリが見つからない: \(scanRoot.path)"); continue
            }
            for case let url as URL in e {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    if excludedDirNames.contains(url.lastPathComponent) { e.skipDescendants() }
                    continue
                }
                guard url.pathExtension == "swift" else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                let imports = text.components(separatedBy: "\n").contains { line in
                    pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                }
                guard imports else { continue }
                let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
                if !rel.hasPrefix("Sources/AppCore/") { offenders.append(rel) }
            }
        }
        #expect(offenders.isEmpty, "StackNestViewerKit を AppCore の外で直接 import している: \(offenders)")
    }

    /// `Info.plist` の宣言の読み方が部品と同じ（真偽値・実数・文字列・0 以下を捨て、宣言の順に正の整数だけ）。
    @Test func declarationReadingMatchesTheKit() throws {
        let declared: [Any] = [true, 1, 1.5, "2", 0, -3, 2]
        let plist = ReferenceViewerSupportTests.declaring(declared)
        let app = try ReferenceViewerSupportTests.makeApp(plist: plist)
        defer { ReferenceViewerSupportTests.remove(app) }
        let declaration = try #require(ViewerSupportDeclaration.read(appURL: app))
        #expect(declaration.referenceFormatVersions == [1, 2])
        #expect(declaration.referenceFormatVersions == StackNestViewerSupport.declaredVersions(in: plist))
    }
}
