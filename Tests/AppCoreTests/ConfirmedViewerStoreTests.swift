// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

/// G60 v3: 確認できた対応ビューアの記録と、設定に出す状態（spec §5.7）。
@Suite("G60 v3: 確認できた対応ビューア")
struct ConfirmedViewerStoreTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func freshDefaults() -> (UserDefaults, () -> Void) {
        let name = "g60v3-confirmed-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (d, { d.removePersistentDomain(forName: name) })
    }

    @Test func recordsByTheAppsBundleIdentifierWithTheHeadersVersion() {
        let (d, done) = freshDefaults(); defer { done() }
        let store = ConfirmedViewerStore(defaults: d)
        let saved = store.record(appBundleIdentifier: "com.example.FakeViewer",
                                 viewer: "com.example.viewer/1.80; format=1", at: t0)
        #expect(saved == ConfirmedViewer(bundleIdentifier: "com.example.FakeViewer", viewerVersion: "1.80",
                                         formatVersion: 1, confirmedAt: t0))
        #expect(store.confirmed(bundleIdentifier: "com.example.fakeviewer")?.viewerVersion == "1.80",
                "bundle id は大文字小文字を区別しない")
        #expect(store.confirmed(bundleIdentifier: "com.example.viewer") == nil, "鍵は名乗りではなく渡した先のアプリ")
        // 読み直しても残る。
        #expect(ConfirmedViewerStore(defaults: d).confirmed(bundleIdentifier: "com.example.FakeViewer")?.formatVersion == 1)
    }

    @Test func keepsTheLatest() {
        let (d, done) = freshDefaults(); defer { done() }
        let store = ConfirmedViewerStore(defaults: d)
        store.record(appBundleIdentifier: "com.example.fakeviewer", viewer: "com.example.fakeviewer/1.80; format=1", at: t0)
        store.record(appBundleIdentifier: "com.example.fakeviewer", viewer: "com.example.fakeviewer/1.70; format=1",
                     at: t0.addingTimeInterval(-60))
        #expect(store.confirmed(bundleIdentifier: "com.example.fakeviewer")?.viewerVersion == "1.80", "古い日時では上書きしない")
        store.record(appBundleIdentifier: "com.example.fakeviewer", viewer: "com.example.fakeviewer/1.90; format=1",
                     at: t0.addingTimeInterval(60))
        #expect(store.confirmed(bundleIdentifier: "com.example.fakeviewer")?.viewerVersion == "1.90")
    }

    @Test func fallsBackToTheHeaderAndSkipsWhenThereIsNoIdentifier() {
        let (d, done) = freshDefaults(); defer { done() }
        let store = ConfirmedViewerStore(defaults: d)
        store.record(appBundleIdentifier: nil, viewer: "com.example.viewer/2.0; format=1", at: t0)
        #expect(store.confirmed(bundleIdentifier: "com.example.viewer")?.viewerVersion == "2.0")
        #expect(store.record(appBundleIdentifier: nil, viewer: nil, at: t0) == nil)
        let noHeader = store.record(appBundleIdentifier: "com.example.quiet", viewer: nil, at: t0)
        #expect(noHeader?.viewerVersion == nil, "名乗りが無ければ版は分からない")
        #expect(noHeader?.formatVersion == nil)
    }

    @Test func statusFollowsTheDeclarationAndTheRecord() throws {
        let (d, done) = freshDefaults(); defer { done() }
        let store = ConfirmedViewerStore(defaults: d)
        #expect(ExternalViewerSupportStatus.make(appPath: nil, confirmed: store) == .none)
        #expect(ExternalViewerSupportStatus.make(appPath: "", confirmed: store) == .none)
        #expect(ExternalViewerSupportStatus.make(
            appPath: FileManager.default.temporaryDirectory.appendingPathComponent("Nope-\(UUID().uuidString).app").path,
            confirmed: store) == .none)

        let plain = try ReferenceViewerSupportTests.makeApp(plist: ["CFBundleName": "Plain Viewer"])
        defer { ReferenceViewerSupportTests.remove(plain) }
        #expect(ExternalViewerSupportStatus.make(appPath: plain.path, confirmed: store) == .unsupported(appName: "Plain Viewer"))

        let noPlist = try ReferenceViewerSupportTests.makeApp(plist: nil, name: "NoPlist")
        defer { ReferenceViewerSupportTests.remove(noPlist) }
        #expect(ExternalViewerSupportStatus.make(appPath: noPlist.path, confirmed: store) == .unsupported(appName: "NoPlist"))

        let declared = try ReferenceViewerSupportTests.makeApp(plist: ReferenceViewerSupportTests.declaring([1]))
        defer { ReferenceViewerSupportTests.remove(declared) }
        #expect(ExternalViewerSupportStatus.make(appPath: declared.path, confirmed: store) == .declared(appName: "Example Viewer"))

        store.record(appBundleIdentifier: "com.example.viewer", viewer: "com.example.viewer/1.80; format=1", at: t0)
        #expect(ExternalViewerSupportStatus.make(appPath: declared.path, confirmed: store)
                == .confirmed(appName: "Example Viewer", at: t0, viewerVersion: "1.80"))

        // 宣言を外したら、記録があっても未対応（判定は宣言が先）。
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.viewer",
                                                              "CFBundleName": "Example Viewer"],
                                           format: .xml, options: 0)
            .write(to: declared.appendingPathComponent("Contents/Info.plist"))
        #expect(ExternalViewerSupportStatus.make(appPath: declared.path, confirmed: store) == .unsupported(appName: "Example Viewer"))
    }

    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    /// 設定の状態の行が開いたまま更新されるための知らせ。記録を変えたときだけ投げる。
    @Test func postsAChangeOnlyWhenItRecords() {
        let (d, done) = freshDefaults(); defer { done() }
        let store = ConfirmedViewerStore(defaults: d)
        let count = Count()
        let observer = NotificationCenter.default.addObserver(
            forName: .confirmedViewersDidChange, object: store, queue: nil) { _ in count.add() }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.record(appBundleIdentifier: "com.example.fakeviewer", viewer: nil, at: t0)
        #expect(count.value == 1)
        store.record(appBundleIdentifier: "com.example.fakeviewer", viewer: nil, at: t0.addingTimeInterval(-60))
        #expect(count.value == 1, "古い日時で何も変えなければ知らせない")
        store.record(appBundleIdentifier: nil, viewer: nil, at: t0)
        #expect(count.value == 1, "記録しなければ知らせない")
        store.record(appBundleIdentifier: "com.example.fakeviewer", viewer: nil, at: t0.addingTimeInterval(60))
        #expect(count.value == 2)
    }

    /// G60 §5.9 の作業で直した不具合: 送る側が `_`・`+` を含む bundle id と `kit=` を付けた名乗りでも、版と format を記録する。
    @Test func recordsTheVersionFromAKitStyleHeader() {
        let (d, done) = freshDefaults(); defer { done() }
        let store = ConfirmedViewerStore(defaults: d)
        let saved = store.record(appBundleIdentifier: "com.example.my_viewer",
                                 viewer: "com.example.my_viewer/1.2.3; format=1; kit=0.1.0", at: t0)
        #expect(saved?.viewerVersion == "1.2.3")
        #expect(saved?.formatVersion == 1)
        // 渡した先のアプリの bundle id が無くても、名乗りの bundle id で記録する。
        let byHeader = store.record(appBundleIdentifier: nil, viewer: "com.example.other+viewer/2.0; format=1", at: t0)
        #expect(byHeader?.bundleIdentifier == "com.example.other+viewer")
    }
}
