// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryServerAPI
import LibraryStore
import AppCore
@testable import LibraryServer

/// 配信の一覧を差し替えられるデータソース（共有を切った・閉じた、を再現する）。
private final class MutableLibraryDataSource: LibraryServerDataSource, @unchecked Sendable {
    private let lock = NSLock()
    private var libraries: [ServedLibrary]
    init(_ libraries: [ServedLibrary]) { self.libraries = libraries }
    func set(_ libraries: [ServedLibrary]) { lock.withLock { self.libraries = libraries } }
    func servedLibraries() async -> [ServedLibrary] { lock.withLock { libraries } }
}

/// G62b: 配信していない書庫（共有 OFF・共有したことがない・閉じた）のライブイベントは送らない。
///
/// 以前（G8a〜G62）は scope だけで絞っていたため、scope `.all` の購読者（固定トークンなど）に
/// 共有していない書庫の UUID・本の ID・編集の時刻が流れていた。施錠して共有していた書庫の共有を切ると、
/// G23 の丸め（配信中の施錠庫だけが対象）も外れて本の ID がそのまま出ていた。
///
/// 「届かない」はタイムアウトで待たず、後から配信中の書庫のイベント（番兵）を流し、
/// 最初に届くのが番兵であることで確かめる（publish は順に await するので、
/// 落とされなかったイベントは番兵より先に届く）。
@Suite("G62b: 配信していない書庫のライブイベントは送らない")
struct UnservedLiveEventTests {
    @Test func eventsOfAnUnservedLibraryAreDroppedWhileServedOnesArrive() async throws {
        let fa = try TestLibraryFixture(name: "G62b-A", bookCount: 1); defer { fa.cleanup() }
        let fb = try TestLibraryFixture(name: "G62b-B", bookCount: 1); defer { fb.cleanup() }
        let a = fa.servedLibrary()
        let b = fb.servedLibrary()
        let core = LibraryServerCore(config: .init(port: 0, token: "tk"),
                                     dataSource: StaticLibraryDataSource(libraries: [a]))
        let sub = await core.eventHub.subscribe(scope: .all)
        var it = sub.stream.makeAsyncIterator()

        await core.eventHub.publish(.bookChanged(library: b.uuid, bookID: 4711))
        await core.eventHub.publish(.structureChanged(library: b.uuid))
        await core.eventHub.publish(.settingsChanged(library: b.uuid))
        await core.eventHub.publish(.bookChanged(library: a.uuid, bookID: 1))
        await core.eventHub.publish(.structureChanged(library: a.uuid))

        #expect(await it.next() == .bookChanged(library: a.uuid, bookID: 1))
        #expect(await it.next() == .structureChanged(library: a.uuid))
        await core.eventHub.unsubscribe(sub.id)
    }

    /// 施錠して共有していた書庫の共有を切ったら、丸めずに流すのではなく送らない。
    @Test func aLockedLibraryThatStopsBeingServedIsDroppedNotPassedRaw() async throws {
        let locked = try TestLibraryFixture(name: "G62b-L", bookCount: 1, locked: true, password: "pw")
        defer { locked.cleanup() }
        let sentinel = try TestLibraryFixture(name: "G62b-S", bookCount: 1); defer { sentinel.cleanup() }
        let l = locked.servedLibrary()
        let s = sentinel.servedLibrary()
        let source = MutableLibraryDataSource([l, s])
        let core = LibraryServerCore(config: .init(port: 0, token: "tk"), dataSource: source)
        let sub = await core.eventHub.subscribe(scope: .all)
        var it = sub.stream.makeAsyncIterator()

        // 配信中の施錠庫は G23 のとおり丸める。
        await core.eventHub.publish(.bookChanged(library: l.uuid, bookID: 7))
        #expect(await it.next() == .structureChanged(library: l.uuid))

        // 共有を切った（一覧から外れた）後は、丸めた形でも生の形でも送らない。
        source.set([s])
        await core.eventHub.publish(.bookChanged(library: l.uuid, bookID: 8))
        await core.eventHub.publish(.structureChanged(library: l.uuid))
        await core.eventHub.publish(.bookChanged(library: s.uuid, bookID: 1))
        #expect(await it.next() == .bookChanged(library: s.uuid, bookID: 1))
        await core.eventHub.unsubscribe(sub.id)
    }

    /// メンテナンスの進捗・完了も書庫に紐づくイベントなので、配信していない書庫の分は送らない。
    @Test func maintenanceEventsOfAnUnservedLibraryAreDropped() async throws {
        let fa = try TestLibraryFixture(name: "G62b-MA", bookCount: 1); defer { fa.cleanup() }
        let a = fa.servedLibrary()
        let unserved = UUID().uuidString
        let core = LibraryServerCore(config: .init(port: 0, token: "tk"),
                                     dataSource: StaticLibraryDataSource(libraries: [a]))
        let sub = await core.eventHub.subscribe(scope: .all)
        var it = sub.stream.makeAsyncIterator()

        await core.eventHub.publish(.maintenanceProgress(library: unserved, job: "full-scan", done: 1, total: 2))
        await core.eventHub.publish(.maintenanceFinished(library: unserved, job: "full-scan", outcome: "done", count: 2))
        await core.eventHub.publish(.structureChanged(library: a.uuid))
        #expect(await it.next() == .structureChanged(library: a.uuid))
        await core.eventHub.unsubscribe(sub.id)
    }

    /// 共有のメンテナンス fanout（ServerController と LocalControlController が共有する）を経て
    /// 配信していない書庫のジョブのイベントが来ても、このコアの購読者には届かない。
    @Test func sharedMaintenanceFanoutDoesNotLeakAnUnservedLibrarysJob() async throws {
        let served = try TestLibraryFixture(name: "G62b-FS", bookCount: 0); defer { served.cleanup() }
        let other = try TestLibraryFixture(name: "G62b-FO", bookCount: 0); defer { other.cleanup() }
        let s = served.servedLibrary()
        let o = other.servedLibrary()
        let fanout = MaintenanceEventFanout()
        let registry = MaintenanceJobRegistry(
            onProgress: { l, j, d, t in fanout.broadcastProgress(l, j, d, t) },
            onFinished: { l, j, oc, c in fanout.broadcastFinished(l, j, oc, c) })
        let core = LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: true),
            dataSource: StaticLibraryDataSource(libraries: [s]),
            maintenanceRegistry: registry, maintenanceEventFanout: fanout)
        let sub = await core.eventHub.subscribe(scope: .all)
        var it = sub.stream.makeAsyncIterator()

        // 配信していない書庫 o のジョブ（例: CLI から起動した整合性チェック）。
        let started = await registry.start(library: o.uuid, job: "full-scan") { progress, _ in
            progress(1, 1)
            return 1
        }
        #expect(started == true)
        try await waitForMaintenanceJobToFinish(registry: registry, library: o.uuid)
        // fanout の publish は fire-and-forget の Task なので、少し待ってから番兵を流す。
        try await Task.sleep(for: .milliseconds(200))
        await core.eventHub.publish(.structureChanged(library: s.uuid))
        #expect(await it.next() == .structureChanged(library: s.uuid))
        await core.eventHub.unsubscribe(sub.id)
    }
}
