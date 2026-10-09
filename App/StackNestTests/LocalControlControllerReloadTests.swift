// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryServer
import RemoteClient
@testable import StackNest

/// G60 最終レビュー I-1: `reload()` を立て続けに呼んでも、自分の旧サーバとのポート競合で
/// ポートを取り直さない（取り直すと、書き出し済みの参照ファイルが古いポートを指したまま使えなくなる）。
///
/// 本物のサーバも実ポートも UserDefaults.standard も使わない。`LocalControlController` の継ぎ目に
/// 偽のサーバ（ポートの占有を模す）と偽のポートの置き場を差し込む。
@MainActor
@Suite("G60: ローカル制御の再起動の直列化", .serialized)
struct LocalControlControllerReloadTests {
    /// 偽のポートの置き場と、偽のサーバが占有しているポート。
    @MainActor final class FakePorts {
        var stored = 50_001
        var regenerated = 0
        var bound: Set<Int> = []
    }

    /// 偽のサーバ。ポートが使われていれば EADDRINUSE を投げる。取り消されるまで占有し、
    /// 取り消された後も少し遅れて（本物の graceful shutdown のように）ポートを放す。
    func runner(_ ports: FakePorts) -> @MainActor (Int, LocalEndpointMode) async throws -> Void {
        { port, _ in
            if ports.bound.contains(port) { throw POSIXError(.EADDRINUSE) }
            ports.bound.insert(port)
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            // 取り消しの効かない後始末の時間。
            await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
            ports.bound.remove(port)
        }
    }

    func makeController(_ ports: FakePorts, mode: LocalEndpointMode? = .full) -> LocalControlController {
        let c = LocalControlController()
        c.endpointModeProvider = { mode }
        c.portProvider = { ports.stored }
        c.portRegenerator = {
            ports.regenerated += 1
            ports.stored += 1
            return ports.stored
        }
        c.serverRunnerOverride = runner(ports)
        return c
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            if ContinuousClock.now >= deadline { Issue.record("待ちきれなかった"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// 走っているサーバに `reload()` を 2 回続けて送る。ポートは変わらず、最後に 1 つだけ走っている。
    @Test func twoRapidReloadsKeepThePortAndEndWithOneServer() async throws {
        let ports = FakePorts()
        let c = makeController(ports)
        c.startIfEnabled()
        try await waitUntil { ports.bound == [50_001] }

        c.reload()
        c.reload()
        // 再起動が落ち着くまで待つ（偽サーバの後始末は 50ms）。
        try await Task.sleep(for: .milliseconds(400))
        try await waitUntil { c.isRunning && ports.bound.count == 1 }

        #expect(ports.regenerated == 0, "自分の旧サーバとの競合でポートを取り直さない")
        #expect(ports.stored == 50_001)
        #expect(ports.bound == [50_001])
        #expect(c.isRunning)

        c.stop()
        try await waitUntil { ports.bound.isEmpty }
    }

    /// 本当に別のプロセスがポートを使っているときは、従来どおり取り直して起動する。
    @Test func aPortHeldByAnotherProcessIsStillRegenerated() async throws {
        let ports = FakePorts()
        ports.bound = [50_001]   // 別のプロセスが占有
        let c = makeController(ports)

        c.startIfEnabled()
        try await waitUntil { ports.bound.contains(50_002) }

        #expect(ports.regenerated == 1)
        #expect(ports.stored == 50_002)
        #expect(c.isRunning)

        c.stop()
        try await waitUntil { !ports.bound.contains(50_002) }
    }

    /// 終了時の `stop()` は、待ちの途中の再起動も取り消す（終了した後にサーバを起こさない）。
    @Test func stopCancelsAPendingRestart() async throws {
        let ports = FakePorts()
        let c = makeController(ports)
        c.startIfEnabled()
        try await waitUntil { ports.bound == [50_001] }

        c.reload()
        c.stop()
        try await Task.sleep(for: .milliseconds(400))

        #expect(ports.bound.isEmpty, "stop() の後にサーバが起動していない")
        #expect(!c.isRunning)
    }

    // MARK: - G60 §5.9: 中継の本の先読み

    @MainActor final class StopCount { var value = 0 }
    @MainActor final class ModeBox {
        var value: LocalEndpointMode?
        init(_ value: LocalEndpointMode?) { self.value = value }
    }

    /// 127.0.0.1 の口の中継は、内蔵ビューアと同じリモートのキャッシュ（使うときに引く）を使い、先読み係を持つ。
    @Test func theRelayUsesTheSharedRemoteCache() {
        let c = LocalControlController()
        #expect(c.viewerRelay.pageCache is RemotePageCacheRelayAdapter)
        #expect(c.viewerRelay.prefetcher != nil)
    }

    /// 中継の先読みの範囲は、内蔵ビューアと同じ設定「開いた本を全ページ先読みする」に従う（配線を固定する）。
    @Test func theRelayFollowsTheWholeBookPrefetchSetting() {
        let original = RemoteCacheSettings.wholeBookPrefetch()
        defer { RemoteCacheSettings.setWholeBookPrefetch(original) }
        let c = LocalControlController()
        RemoteCacheSettings.setWholeBookPrefetch(true)
        #expect(c.viewerRelay.wholeBookPrefetch())
        RemoteCacheSettings.setWholeBookPrefetch(false)
        #expect(!c.viewerRelay.wholeBookPrefetch())
    }

    /// 口を止めたら（StackNest の終了もここを通る）、中継の本の先読みも止める。
    @Test func stopAlsoStopsTheRelayPrefetch() async throws {
        let ports = FakePorts()
        let c = makeController(ports)
        let stops = StopCount()
        c.stopRelayPrefetch = { _ in stops.value += 1 }
        c.startIfEnabled()
        try await waitUntil { ports.bound == [50_001] }

        c.stop()

        #expect(stops.value == 1)
        try await waitUntil { ports.bound.isEmpty }
    }

    /// 再構成で口が起動しなくなる（同期もローカルコントロールも OFF）なら止める。口が起動し直すなら止めない
    /// （中継の記録はメモリに残っていて、ビューアは同じ口で読み続けられる）。
    @Test func reloadStopsThePrefetchOnlyWhenTheEndpointGoesAway() async throws {
        let ports = FakePorts()
        let mode = ModeBox(.viewerTokensOnly)
        let c = makeController(ports, mode: .viewerTokensOnly)
        c.endpointModeProvider = { mode.value }
        let stops = StopCount()
        c.stopRelayPrefetch = { _ in stops.value += 1 }
        c.startIfEnabled()
        try await waitUntil { ports.bound == [50_001] }

        c.reload()
        try await Task.sleep(for: .milliseconds(200))
        try await waitUntil { c.isRunning && ports.bound.count == 1 }
        #expect(stops.value == 0, "口が起動し直す再構成では止めない")

        mode.value = nil
        c.reload()
        #expect(stops.value == 1)
        try await waitUntil { ports.bound.isEmpty }
        #expect(!c.isRunning)
    }

    /// 「開いた本を全ページ先読みする」を切り替えると（設定の画面のトグルは `RemoteCacheSettings.setWholeBookPrefetch` を通る）、
    /// 127.0.0.1 の口が中継の先読みへ伝える（ON なら、止まっていた先読みを全ページで始め直す）。
    /// 書き込みは suite の defaults にする（`UserDefaults.standard` に触れない）。知らせはどの口も受けるので、
    /// ほかに作られた口は自分の中継へ伝えるだけで何も起きない（渡した本が無い）。
    @Test func wholeBookSettingChangesReachTheRelay() async throws {
        let c = LocalControlController()
        let changes = StopCount()
        c.wholeBookPrefetchChanged = { _ in changes.value += 1 }
        let name = "g60-59-whole-book-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        RemoteCacheSettings.setWholeBookPrefetch(true, defaults)
        try await waitUntil { changes.value == 1 }
        RemoteCacheSettings.setWholeBookPrefetch(false, defaults)
        try await waitUntil { changes.value == 2 }

        #expect(RemoteCacheSettings.wholeBookPrefetch(defaults) == false)
    }
}
