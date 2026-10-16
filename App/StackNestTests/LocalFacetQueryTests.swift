// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Synchronization
import AppCore
import LibraryStore
@testable import StackNest

/// G62（spec §6.7・§8）: ブラウザ区画（ローカル）の問い合わせは MainActor の外で走り、取り消された後の結果を使わない。
@Suite("G62: ブラウザ区画の問い合わせ")
@MainActor
struct LocalFacetQueryTests {
    /// 問い合わせがどのスレッドで走ったかを記録する。
    final class ThreadRecord: Sendable {
        private let onMain = Mutex<Bool?>(nil)
        func record(_ value: Bool) { onMain.withLock { $0 = value } }
        var value: Bool? { onMain.withLock { $0 } }
    }

    /// 問い合わせが呼ばれた回数を数える。
    final class CallCounter: Sendable {
        private let count = Mutex(0)
        func bump() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    /// 問い合わせ（MainActor の外）の中から、呼び出した Task を取り消すための箱。
    final class CallerBox: Sendable {
        private let task = Mutex<Task<[String], Never>?>(nil)
        func set(_ value: Task<[String], Never>) { task.withLock { $0 = value } }
        func cancel() { task.withLock { $0 }?.cancel() }
    }

    private func makeState() throws -> AppState {
        let db = try Database.openInMemory()
        try db.migrate()
        try SyntheticLibrary.generate(into: db, count: 50)
        let state = AppState(bundleURL: URL(fileURLWithPath: "/tmp/g62-facet.stacknest"))
        state.database = db
        state.librarySettings = try LibrarySettings(database: db)
        return state
    }

    @Test func queryRunsOffTheMainThread() async throws {
        let state = try makeState()
        let rec = ThreadRecord()
        state.facetQuery = { _, _ in
            rec.record(Thread.isMainThread)
            return ["x"]
        }
        let values = await state.localFacetValues(columnSQL: "genre", upperConstraints: [])
        #expect(values == ["x"])
        #expect(rec.value == false)
    }

    @Test func theRealQueryStillReturnsValues() async throws {
        let state = try makeState()
        let values = await state.localFacetValues(columnSQL: "genre", upperConstraints: [])
        #expect(!values.isEmpty)   // 合成の書庫にはジャンルが 12 種ある
    }

    /// 呼び出した Task が始まる前に取り消されていたら、問い合わせを走らせない。
    /// 試験は MainActor 上にあり、`Task {}` は MainActor を受け継ぐので、本体は `cancel()` の後の
    /// `await task.value` まで始まらない（入口で必ず取り消し済みを見る）。
    @Test func anAlreadyCancelledCallerDoesNotRunTheQuery() async throws {
        let state = try makeState()
        let calls = CallCounter()
        state.facetQuery = { _, _ in
            calls.bump()
            return ["x"]
        }
        let task = Task { await state.localFacetValues(columnSQL: "genre", upperConstraints: []) }
        task.cancel()
        let values = await task.value
        #expect(values.isEmpty)
        #expect(calls.value == 0)
        #expect(state.error == nil)
    }

    /// 問い合わせが走っている間に取り消されたら、失敗してもエラーを出さない。
    /// 問い合わせの中から呼び出した Task を取り消す（入口の検査は通った後。スレッドを塞いで待たない）。
    @Test func aCancelledCallerGetsNoValuesAndNoError() async throws {
        let state = try makeState()
        let caller = CallerBox()
        let calls = CallCounter()
        state.facetQuery = { _, _ in
            calls.bump()
            caller.cancel()
            throw CocoaError(.fileReadUnknown)
        }
        let task = Task { await state.localFacetValues(columnSQL: "genre", upperConstraints: []) }
        caller.set(task)   // 本体は試験が待つまで始まらないので、問い合わせより先に入る
        let values = await task.value
        #expect(calls.value == 1)   // 入口の検査ではなく、待ちの後の検査で捨てた
        #expect(values.isEmpty)
        #expect(state.error == nil)
    }

    /// 問い合わせが走っている間に取り消されたら、成功した結果も捨てる。
    @Test func aCancellationDuringTheQueryDropsTheValues() async throws {
        let state = try makeState()
        let caller = CallerBox()
        let calls = CallCounter()
        state.facetQuery = { _, _ in
            calls.bump()
            caller.cancel()
            return ["stale"]
        }
        let task = Task { await state.localFacetValues(columnSQL: "genre", upperConstraints: []) }
        caller.set(task)
        let values = await task.value
        #expect(calls.value == 1)
        #expect(values.isEmpty)
        #expect(state.error == nil)
    }

    @Test func aFailureIsShownWhenNotCancelled() async throws {
        let state = try makeState()
        state.facetQuery = { _, _ in throw CocoaError(.fileReadUnknown) }
        _ = await state.localFacetValues(columnSQL: "genre", upperConstraints: [])
        #expect(state.error != nil)
    }

    /// 鍵が変わって取り消された `loadValues` は、古い結果で新しい値を上書きしない。
    @Test func aCancelledLoadDoesNotAssign() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            await BrowserColumnView.fetchUnlessCancelled {
                for await _ in stream { break }   // 取り消されると待ちが終わる
                return ["old"]
            }
        }
        task.cancel()
        #expect(await task.value == nil)
        continuation.finish()
    }

    @Test func anUncancelledLoadAssigns() async {
        let task = Task { await BrowserColumnView.fetchUnlessCancelled { ["new"] } }
        #expect(await task.value == ["new"])
    }
}
