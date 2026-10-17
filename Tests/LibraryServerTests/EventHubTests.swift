// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServer
import LibraryServerAPI

@Suite("EventHub")
struct EventHubTests {
    @Test func publishReachesInScopeSubscriberOnly() async throws {
        let hub = EventHub()
        let a = await hub.subscribe(scope: .all)
        let b = await hub.subscribe(scope: .libraries(["other"]))   // "u1" を含まない scope
        await hub.publish(.bookChanged(library: "u1", bookID: 7))
        // a（.all）は受信
        var itA = a.stream.makeAsyncIterator()
        #expect(await itA.next() == .bookChanged(library: "u1", bookID: 7))
        // b（scope 外）へは届かない → unsubscribe で finish させ nil を確認
        await hub.unsubscribe(b.id)
        var itB = b.stream.makeAsyncIterator()
        #expect(await itB.next() == nil)
    }

    @Test func unsubscribeStopsDelivery() async throws {
        let hub = EventHub()
        let s = await hub.subscribe(scope: .all)
        await hub.unsubscribe(s.id)
        await hub.publish(.structureChanged(library: "u1"))
        var it = s.stream.makeAsyncIterator()
        #expect(await it.next() == nil)   // 解除後は finish 済みで nil
    }

    // MARK: - G23 (#15): 施錠庫のイベント粒度

    /// 施錠庫の bookChanged は bookID を落として structureChanged に丸める。
    /// bookID は連番のため、そのまま流すと未解錠のクライアントに蔵書数の概算が漏れる。
    @Test func lockedLibraryBookChangedIsCoarsened() async throws {
        let hub = EventHub(isLibraryLocked: { $0 == "locked" })
        let s = await hub.subscribe(scope: .all)
        await hub.publish(.bookChanged(library: "locked", bookID: 42))
        var it = s.stream.makeAsyncIterator()
        #expect(await it.next() == .structureChanged(library: "locked"))
        await hub.unsubscribe(s.id)
    }

    /// 非施錠庫は従来どおり bookID を保つ（ライブ同期の粒度を落とさない）。
    @Test func unlockedLibraryKeepsBookID() async throws {
        let hub = EventHub(isLibraryLocked: { _ in false })
        let s = await hub.subscribe(scope: .all)
        await hub.publish(.bookChanged(library: "open", bookID: 7))
        var it = s.stream.makeAsyncIterator()
        #expect(await it.next() == .bookChanged(library: "open", bookID: 7))
        await hub.unsubscribe(s.id)
    }

    /// 施錠庫でも structureChanged 等はそのまま流す（変更の事実は既に GET /libraries で公開されている）。
    @Test func lockedLibraryStillDeliversNonBookEvents() async throws {
        let hub = EventHub(isLibraryLocked: { _ in true })
        let s = await hub.subscribe(scope: .all)
        await hub.publish(.settingsChanged(library: "locked"))
        var it = s.stream.makeAsyncIterator()
        #expect(await it.next() == .settingsChanged(library: "locked"))
        await hub.unsubscribe(s.id)
    }

    /// scope 外へは施錠の有無にかかわらず届かない（既存のフィルタを壊していない）。
    @Test func scopeStillFiltersForLockedLibraries() async throws {
        let hub = EventHub(isLibraryLocked: { _ in true })
        let s = await hub.subscribe(scope: .libraries(["other"]))
        await hub.publish(.bookChanged(library: "locked", bookID: 1))
        await hub.unsubscribe(s.id)
        var it = s.stream.makeAsyncIterator()
        #expect(await it.next() == nil)
    }

    // MARK: - G62b: 配信していない書庫のイベントは送らない

    /// 書庫に紐づくイベントは種類を問わず、`.unserved` の書庫の分は scope `.all` にも届かない。
    @Test func unservedLibraryEventsOfEveryKindAreDropped() async throws {
        let hub = EventHub(libraryState: { $0 == "served" ? .unlocked : .unserved })
        let s = await hub.subscribe(scope: .all)
        await hub.publish(.bookChanged(library: "hidden", bookID: 1))
        await hub.publish(.structureChanged(library: "hidden"))
        await hub.publish(.settingsChanged(library: "hidden"))
        await hub.publish(.maintenanceProgress(library: "hidden", job: "full-scan", done: 1, total: 2))
        await hub.publish(.maintenanceFinished(library: "hidden", job: "full-scan", outcome: "done", count: 2))
        await hub.publish(.bookChanged(library: "served", bookID: 9))
        var it = s.stream.makeAsyncIterator()
        #expect(await it.next() == .bookChanged(library: "served", bookID: 9))
        await hub.unsubscribe(s.id)
    }

    /// 新しい形の `.locked` も G23 と同じに丸める。
    @Test func lockedStateCoarsensLikeBefore() async throws {
        let hub = EventHub(libraryState: { _ in .locked })
        let s = await hub.subscribe(scope: .all)
        await hub.publish(.bookChanged(library: "locked", bookID: 42))
        await hub.publish(.settingsChanged(library: "locked"))
        var it = s.stream.makeAsyncIterator()
        #expect(await it.next() == .structureChanged(library: "locked"))
        #expect(await it.next() == .settingsChanged(library: "locked"))
        await hub.unsubscribe(s.id)
    }
}
