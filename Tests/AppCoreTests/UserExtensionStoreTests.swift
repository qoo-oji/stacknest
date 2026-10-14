// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G64: 足した拡張子の保存・読み飛ばし・通知（spec §6.1）。suite の UserDefaults だけを使い、`shared` に触れない。
@Suite("G64: 足した拡張子の一覧の保存")
struct UserExtensionStoreTests {
    private func makeSuite() -> (UserDefaults, String) {
        let name = "g64-store-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// 通知を数える（`object` が自分の store のものだけ）。
    private final class ChangeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        private var token: NSObjectProtocol?
        init(store: UserExtensionStore) {
            token = NotificationCenter.default.addObserver(
                forName: .userExtensionsDidChange, object: store, queue: nil) { [weak self] _ in
                    guard let self else { return }
                    self.lock.withLock { self.n += 1 }
                }
        }
        var count: Int { lock.withLock { n } }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }

    @Test("書いて読み戻す（plist の辞書・別のインスタンスでも同じ）")
    func roundTrip() throws {
        let (defaults, name) = makeSuite(); defer { defaults.removePersistentDomain(forName: name) }
        let store = UserExtensionStore(defaults: defaults)
        #expect(store.snapshot.isEmpty)
        #expect(store.add("*.TGZ", category: .archive) == .success("tgz"))
        #expect(store.add("docx", category: .text) == .success("docx"))
        #expect(store.snapshot == ["tgz": .archive, "docx": .text])
        let raw = try #require(defaults.dictionary(forKey: UserExtensionStore.defaultsKey) as? [String: String])
        #expect(raw == ["tgz": "archive", "docx": "text"])
        #expect(UserExtensionStore(defaults: defaults).snapshot == ["tgz": .archive, "docx": .text])
    }

    @Test("壊れた項目だけを読み飛ばし、ほかは残る")
    func skipsBadEntriesOneByOne() {
        let (defaults, name) = makeSuite(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set([
            "tgz": "archive",          // 残る
            "avif": "image",           // 残る
            "djvu": "comic",           // 知らない種類
            "dir": "folder",           // フォルダは振り分け先に無い
            "a.b": "archive",          // 形が合わない
            "TGX": "archive",          // 大文字（正規化されていない）
            "cbt": "text",             // 標準と重なる（G64 より前の試用版で足していた例）
            "zip": "text",             // 標準と重なる
            "tmp": "archive",          // 予約
            "num": 3,                  // 値が文字列でない
        ] as [String: Any], forKey: UserExtensionStore.defaultsKey)
        #expect(UserExtensionStore(defaults: defaults).snapshot == ["tgz": .archive, "avif": .image])
    }

    @Test("辞書でない値は空として扱う")
    func nonDictionaryIsEmpty() {
        let (defaults, name) = makeSuite(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("tgz=archive", forKey: UserExtensionStore.defaultsKey)
        #expect(UserExtensionStore(defaults: defaults).snapshot.isEmpty)
    }

    @Test("読み飛ばした項目は次の書き込みで消える")
    func nextWriteDropsSkippedEntries() throws {
        let (defaults, name) = makeSuite(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["tgz": "archive", "cbt": "text"], forKey: UserExtensionStore.defaultsKey)
        let store = UserExtensionStore(defaults: defaults)
        #expect(store.add("avif", category: .image) == .success("avif"))
        let raw = try #require(defaults.dictionary(forKey: UserExtensionStore.defaultsKey) as? [String: String])
        #expect(raw == ["tgz": "archive", "avif": "image"])
    }

    @Test("書き込みでスナップショットが変わり、変えたときだけ通知する")
    func writesUpdateSnapshotAndNotify() {
        let (defaults, name) = makeSuite(); defer { defaults.removePersistentDomain(forName: name) }
        let store = UserExtensionStore(defaults: defaults)
        let counter = ChangeCounter(store: store)

        #expect(store.add("tgz", category: .archive) == .success("tgz"))
        #expect(counter.count == 1)
        #expect(store.add("TGZ", category: .text) == .failure(.alreadyAdded("tgz")))
        #expect(store.add("zip", category: .archive) == .failure(.standard("zip")))
        #expect(counter.count == 1, "断ったときは通知しない")
        #expect(store.snapshot == ["tgz": .archive])

        #expect(store.setCategory(.text, for: "tgz"))
        #expect(store.snapshot == ["tgz": .text])
        #expect(counter.count == 2)
        #expect(!store.setCategory(.text, for: "tgz"), "同じ種類は変えない")
        #expect(!store.setCategory(.image, for: "nope"), "足していない拡張子は変えない")
        #expect(counter.count == 2)

        #expect(store.remove("tgz"))
        #expect(store.snapshot.isEmpty)
        #expect(defaults.object(forKey: UserExtensionStore.defaultsKey) == nil, "空になったらキーを消す")
        #expect(counter.count == 3)
        #expect(!store.remove("tgz"))
        #expect(counter.count == 3)
    }

    @Test("ほかの store の書き込みでは通知が届かない（suite を分けたテスト同士が干渉しない）")
    func notificationsAreScopedToTheStore() {
        let (d1, n1) = makeSuite(); defer { d1.removePersistentDomain(forName: n1) }
        let (d2, n2) = makeSuite(); defer { d2.removePersistentDomain(forName: n2) }
        let a = UserExtensionStore(defaults: d1)
        let b = UserExtensionStore(defaults: d2)
        let counter = ChangeCounter(store: a)
        b.add("tgz", category: .archive)
        #expect(counter.count == 0)
        #expect(a.snapshot.isEmpty)
    }

    @Test("100 個目までは足せ、101 個目は断る（保存されない）")
    func limitIsEnforcedOnAdd() {
        let (defaults, name) = makeSuite(); defer { defaults.removePersistentDomain(forName: name) }
        let store = UserExtensionStore(defaults: defaults)
        for i in 0..<100 { #expect(store.add("x\(i)", category: .archive) == .success("x\(i)")) }
        #expect(store.add("y", category: .archive) == .failure(.limitReached))
        #expect(store.snapshot.count == 100)
        #expect(UserExtensionStore(defaults: defaults).snapshot.count == 100)
    }
}
