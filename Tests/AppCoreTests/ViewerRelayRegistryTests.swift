// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

/// G60 v3（spec §5.8・試用）: リモートの本を 127.0.0.1 の口で中継するための記録と、中継の鍵。
@Suite("G60 v3: リモートの本の中継の記録")
struct ViewerRelayRegistryTests {
    private func target(_ token: String = "REMOTE-SECRET") -> ViewerRelayTarget {
        ViewerRelayTarget(serverID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                          serverBase: URL(string: "http://100.64.0.5:51234/")!,
                          libraryUUID: "LIB-R", bookID: 42, remoteToken: token)
    }

    private func freshDefaults() -> (UserDefaults, () -> Void) {
        let name = "g60v3-relay-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (d, { d.removePersistentDomain(forName: name) })
    }

    @Test func registersAndLooksUp() {
        let registry = ViewerRelayRegistry()
        let a = registry.register(target())
        let b = registry.register(target("OTHER"))
        #expect(a != b, "開くたびに別の中継")
        #expect(registry.target(for: a)?.remoteToken == "REMOTE-SECRET")
        #expect(registry.target(for: b)?.remoteToken == "OTHER")
        #expect(registry.target(for: "no-such-relay") == nil)
        #expect(registry.count == 2)
        #expect(BookReferenceStore.isSafeComponent(a), "relayID は URL の 1 階層にそのまま使える")
    }

    @Test func remoteBookURLIsTheServersBookAPI() {
        #expect(target().remoteBookURL == "http://100.64.0.5:51234/api/v1/libraries/LIB-R/books/42")
    }

    /// リモートの鍵は print・dump・失敗メッセージ・ログに出さない。
    @Test func neverShowsTheRemoteToken() {
        let t = target()
        #expect(!String(describing: t).contains("REMOTE-SECRET"))
        #expect(!String(reflecting: t).contains("REMOTE-SECRET"))
        #expect(!"\(t)".contains("REMOTE-SECRET"))
        var dumped = ""
        dump(t, to: &dumped)
        #expect(!dumped.contains("REMOTE-SECRET"))
        #expect(String(describing: t).contains("<redacted>"))
    }

    @Test func relayURLPointsAtTheLocalEndpoint() {
        #expect(BookReference.relayURL(localBase: URL(string: "http://127.0.0.1:4321/")!, relayID: "R-1")
                == "http://127.0.0.1:4321/api/v1/relay/R-1")
    }

    @Test func relayTokenRecordsItsRelayID() {
        let (d, done) = freshDefaults(); defer { done() }
        let store = ViewerTokenStore(defaults: d)
        let issued = store.issue(libraryUUID: "LIB-R", bookID: 42, issuer: .localEndpoint,
                                 lockCredential: nil, relayID: "R-1")
        #expect(issued.record.relayID == "R-1")
        #expect(ViewerTokenStore(defaults: d).record(id: issued.record.id)?.relayID == "R-1", "保存しても残る")
        let plain = store.issue(libraryUUID: "LIB-R", bookID: 42, issuer: .localEndpoint, lockCredential: nil)
        #expect(plain.record.relayID == nil, "既定は中継の鍵ではない")
    }

    /// v2・v3（中継の前）のビルドが保存した記録には relayID のキーが無い。読めて nil になる
    /// （読めないと `init` が記録を空にし、配った参照ファイルのトークンが全部 401 になる）。
    @Test func recordsWithoutRelayIDStillDecode() throws {
        let (d, done) = freshDefaults(); defer { done() }
        let v3 = """
        [{"id":"R3","tokenHash":"\(ViewerTokenStore.hash("T"))","libraryUUID":"LIB-1","bookID":7,\
        "issuer":"localEndpoint","issuedAt":0,"expiresAt":2000000000,"firstUsedAt":100,\
        "viewer":"com.example.viewer/1.0; format=1"}]
        """
        d.set(Data(v3.utf8), forKey: ViewerTokenStore.defaultsKey)
        let store = ViewerTokenStore(defaults: d)
        let r = try #require(store.record(id: "R3"))
        #expect(r.relayID == nil)
        #expect(r.viewer == "com.example.viewer/1.0; format=1")
        guard case .valid = store.lookup(token: "T", issuer: .localEndpoint) else {
            Issue.record("中継の前の記録のトークンが通らない"); return
        }
    }

    /// 中継するかの判断は 1 か所（試用中は中継する）。
    @Test func relayDecisionIsInOnePlace() {
        #expect(ExternalViewerSyncRouting.relaysRemoteBooks)
    }

    /// レビュー M-4: 中継の記録は期限（中継の鍵とリモートの鍵の早い方）を持ち、切れたら引けない（＝401）。
    /// 切れた記録は引いたときに消える（リモートの鍵の平文を期限の後まで持たない）。
    @Test func expiredRelaysAreNotFoundAndArePruned() {
        let registry = ViewerRelayRegistry()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let short = registry.register(target("SHORT"), expiresAt: t0.addingTimeInterval(60), now: t0)
        let long = registry.register(target("LONG"), expiresAt: t0.addingTimeInterval(3600), now: t0)
        #expect(registry.target(for: short, now: t0.addingTimeInterval(59))?.remoteToken == "SHORT")
        #expect(registry.isLive(short, now: t0.addingTimeInterval(59)))
        #expect(registry.target(for: short, now: t0.addingTimeInterval(60)) == nil, "期限ちょうどで切れる")
        #expect(!registry.isLive(short, now: t0.addingTimeInterval(60)))
        #expect(registry.count == 1, "切れた記録は引いたときに消える")
        #expect(registry.target(for: long, now: t0.addingTimeInterval(60))?.remoteToken == "LONG")
        #expect(registry.target(for: long, now: t0.addingTimeInterval(3600)) == nil)
        #expect(registry.count == 0)
    }

    /// レビュー M-4: 起動時の掃除は、中継の記録がもう無い中継の鍵だけを消す（本の鍵と、生きている中継の鍵は残す）。
    @Test func removeRelayTokensDropsOnlyOrphans() {
        let (d, done) = freshDefaults(); defer { done() }
        let store = ViewerTokenStore(defaults: d)
        let registry = ViewerRelayRegistry()
        let live = registry.register(target())
        let book = store.issue(libraryUUID: "LIB-1", bookID: 1, issuer: .localEndpoint, lockCredential: nil)
        let kept = store.issue(libraryUUID: "LIB-R", bookID: 42, issuer: .localEndpoint,
                               lockCredential: nil, relayID: live)
        let orphan = store.issue(libraryUUID: "LIB-R", bookID: 43, issuer: .localEndpoint,
                                 lockCredential: nil, relayID: "GONE")
        #expect(store.removeRelayTokens(keepingWhere: { registry.isLive($0) }) == 1)
        #expect(store.record(id: book.record.id) != nil)
        #expect(store.record(id: kept.record.id) != nil)
        #expect(store.record(id: orphan.record.id) == nil)
        #expect(ViewerTokenStore(defaults: d).record(id: orphan.record.id) == nil, "保存先からも消える")
        #expect(store.removeRelayTokens(keepingWhere: { registry.isLive($0) }) == 0)
        // 新しく起動した直後（中継の記録が空）は、前回までの中継の鍵をすべて消す。
        #expect(store.removeRelayTokens(keepingWhere: { ViewerRelayRegistry().isLive($0) }) == 1)
        #expect(store.record(id: kept.record.id) == nil)
        #expect(store.record(id: book.record.id) != nil, "本の鍵は残す")
    }
}
