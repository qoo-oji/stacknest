// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

/// 先読みの記録とキャッシュの代わり（閉包は @Sendable なので鍵で包む）。
final class PrefetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var fetchedStorage: [(relayID: String, page: Int)] = []
    private var cachedStorage: Set<Int> = []
    private var sleepStorage: [Duration] = []
    private var eventStorage: [String] = []

    /// 先読みが取りに行った（`stored` なら取れてキャッシュに入った）。
    func fetched(_ relayID: String, _ page: Int, stored: Bool = true) {
        lock.withLock {
            fetchedStorage.append((relayID, page))
            if stored { cachedStorage.insert(page) }
            eventStorage.append("fetch \(page)")
        }
    }
    /// ビューアがそのページを取った（中継のキャッシュに入った）。
    func viewerRead(_ page: Int) {
        lock.withLock { _ = cachedStorage.insert(page) }
    }
    func slept(_ d: Duration) {
        lock.withLock {
            sleepStorage.append(d)
            eventStorage.append("sleep")
        }
    }
    var pages: [Int] { lock.withLock { fetchedStorage.map { $0.page } } }
    func pages(of relayID: String) -> [Int] {
        lock.withLock { fetchedStorage.filter { $0.relayID == relayID }.map { $0.page } }
    }
    var cached: Set<Int> { lock.withLock { cachedStorage } }
    var sleeps: [Duration] { lock.withLock { sleepStorage } }
    var events: [String] { lock.withLock { eventStorage } }
}

/// 閉包から、まだ作っていない先読み係を指すための箱。
final class PrefetcherRef: @unchecked Sendable {
    var value: ViewerRelayPrefetcher?
}

/// 内蔵の「開いた本を全ページ先読みする」の代わり（先読み係は取るページを 1 枚選ぶたびに読む）。
final class WholeBookSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ on: Bool) { stored = on }
    var on: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// ページごとの試行の回数。
final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int: Int] = [:]
    func next(_ page: Int) -> Int {
        lock.withLock {
            counts[page, default: 0] += 1
            return counts[page]!
        }
    }
}

/// 同時に走っている数の最大を数える。
actor ConcurrencyGauge {
    private var current = 0
    private(set) var peak = 0
    /// これまでに入った数（出た後も減らない）。
    private(set) var entered = 0
    func enter() {
        entered += 1
        current += 1
        peak = max(peak, current)
    }
    func leave() { current -= 1 }
}

/// G60 §5.9（2026-10-08 作者の決定）: 外部ビューアに渡したリモートの本の先読み。範囲は内蔵ビューアと同じ設定
/// 「開いた本を全ページ先読みする」に従う（ON＝全ページ・OFF＝内蔵と同じ近傍だけ）。
@Suite("G60 §5.9: 中継の本の先読み（範囲は内蔵と同じ設定に従う）", .timeLimit(.minutes(1)))
struct ViewerRelayPrefetcherTests {
    /// 既定は 1 本ずつ取る（順番を決まった形で見るため）。待ちは記録するだけで、すぐ戻る。
    /// `cachedFromLog` なら、それまでに取れたページとビューアが取ったページをキャッシュにあるものとして返す
    /// （始め直した仕事が取り直さない＝本物の中継がキャッシュを引き直すのと同じ）。
    private func make(pageCount: Int, cached: Set<Int> = [], cachedFromLog: Bool = false,
                      wholeBook: WholeBookSwitch, concurrency: Int = 1,
                      log: PrefetchLog, ref: PrefetcherRef? = nil,
                      sleep: ViewerRelayPrefetcher.Sleep? = nil,
                      fetch: @escaping ViewerRelayPrefetcher.Fetch) -> ViewerRelayPrefetcher {
        let sleeper: ViewerRelayPrefetcher.Sleep = sleep ?? { d in log.slept(d) }
        let p = ViewerRelayPrefetcher(
            tuning: .init(concurrency: concurrency),
            plan: { _ in (pageCount: pageCount, cached: cachedFromLog ? cached.union(log.cached) : cached) },
            fetch: fetch,
            wholeBook: { wholeBook.on },
            sleep: sleeper)
        ref?.value = p
        return p
    }

    // MARK: - 設定が ON（全ページ）

    /// キャッシュに無いページを 1 回ずつ、内蔵ビューアの全ページ先読みと同じ順（中心の先・手前・±10・近い順）で取る。
    @Test func wholeBookOnFetchesEveryMissingPageOnceInTheBuiltInOrder() async {
        let log = PrefetchLog()
        let p = make(pageCount: 8, cached: [2, 5], wholeBook: WholeBookSwitch(true), log: log) { relay, page in
            log.fetched(relay, page)
            return .fetched
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        let builtIn = PrefetchPlanner.plan(current: 0, pageCount: 8, spreadPages: nil, tier3: true).queue
        #expect(log.pages == builtIn.filter { ![2, 5].contains($0) })
        #expect(log.pages == [1, 3, 4, 6, 0, 7])
        #expect(await p.activeRelayID == nil, "全部取ったら終わる")
    }

    /// 1 冊ごとの量の上限は無い（大きな本でも全ページを取る。あふれた分はキャッシュの上限の退避が古い順に消す）。
    @Test func wholeBookHasNoPerBookCap() async {
        let log = PrefetchLog()
        let p = make(pageCount: 300, wholeBook: WholeBookSwitch(true), concurrency: 2, log: log) { relay, page in
            log.fetched(relay, page)
            return .fetched
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.pages.count == 300)
        #expect(Set(log.pages) == Set(0..<300))
    }

    // MARK: - 設定が OFF（内蔵と同じ近傍だけ）

    /// OFF なら、内蔵ビューアが OFF のときと同じ近傍（`PrefetchPlanner` の tier3 なし）だけを取り、取り終えたら終わる。
    /// 開くページ自身は取らない（ビューアが頼む）。
    @Test func settingOffFetchesOnlyTheBuiltInLookahead() async {
        let log = PrefetchLog()
        let p = make(pageCount: 40, wholeBook: WholeBookSwitch(false), log: log) { relay, page in
            log.fetched(relay, page)
            return .fetched
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.pages == PrefetchPlanner.plan(current: 0, pageCount: 40, spreadPages: nil, tier3: false).queue)
        #expect(log.pages == [1, 2, 3, 4, 5, 6, 10, 11, 9])
        #expect(await p.activeRelayID == nil, "近傍を取り終えたら終わる")
    }

    /// OFF のまま読み進めると、ビューアが最後に頼んだページの近傍で始め直す（内蔵ビューアがページを移るたびに近傍を
    /// 取り直すのと同じ）。手前へ戻ったら、近傍も戻る向きを深く取る（内蔵の `navDirection` と同じ）。取ったページは取り直さない。
    @Test func theLookaheadFollowsTheViewerAndItsDirection() async {
        let log = PrefetchLog()
        let p = make(pageCount: 40, cachedFromLog: true, wholeBook: WholeBookSwitch(false), log: log) { relay, page in
            log.fetched(relay, page)
            return .fetched
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.pages == [1, 2, 3, 4, 5, 6, 10, 11, 9])

        // ビューアが 20 ページ目を頼んだ（進む向き）。
        log.viewerRead(20)
        await p.liveRequestBegan(relayID: "R", page: 20)
        await p.liveRequestEnded(relayID: "R")
        await p.waitUntilIdle()
        #expect(Array(log.pages.dropFirst(9)) == [21, 22, 23, 24, 25, 26, 19, 18, 30, 31, 29])

        // 15 ページ目へ戻った（戻る向き）→ 戻る向きに 6 枚・進む向きに 2 枚・±10 のまわり（取ってあるものは除く）。
        log.viewerRead(15)
        await p.liveRequestBegan(relayID: "R", page: 15)
        await p.liveRequestEnded(relayID: "R")
        await p.waitUntilIdle()
        #expect(Array(log.pages.dropFirst(20)) == [14, 13, 12, 16, 17])
        #expect(!log.pages.contains(20) && !log.pages.contains(15), "ビューアが頼んだページは先読みしない")
        #expect(log.pages.count == Set(log.pages).count, "1 回ずつ")
    }

    // MARK: - 設定の切り替え

    /// 全ページの途中で OFF にすると、取り中の 1 枚を取り終えたところで止まる（近傍の残りが無ければそこで終わる）。
    @Test func turningTheSettingOffStopsTheWholeBookAfterTheInFlightPage() async {
        let log = PrefetchLog()
        let setting = WholeBookSwitch(true)
        let p = make(pageCount: 40, wholeBook: setting, log: log) { relay, page in
            log.fetched(relay, page)
            if page == 7 { setting.on = false }   // 7 ページ目を取っているあいだに OFF にした
            return .fetched
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        // ON の順は 1〜6・10・11・9・0・7・8・12…。7 を取り終えた後は近傍（取り終えている）だけ＝そこで終わる。
        #expect(log.pages == [1, 2, 3, 4, 5, 6, 10, 11, 9, 0, 7])
        #expect(await p.activeRelayID == nil)
    }

    /// 近傍を取り終えた後に ON にすると、設定の知らせで、最後に渡した本の全ページの先読みを始める。
    @Test func turningTheSettingOnStartsTheWholeBook() async {
        let log = PrefetchLog()
        let setting = WholeBookSwitch(false)
        let p = make(pageCount: 12, cachedFromLog: true, wholeBook: setting, log: log) { relay, page in
            log.fetched(relay, page)
            return .fetched
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.pages == [1, 2, 3, 4, 5, 6, 10, 11, 9])

        setting.on = true
        await p.wholeBookSettingChanged()
        await p.waitUntilIdle()
        #expect(Array(log.pages.dropFirst(9)) == [0, 7, 8])
        #expect(Set(log.pages) == Set(0..<12))
        #expect(log.pages.count == 12, "取ったページは取り直さない")
    }

    /// 近傍の途中で ON にすると、知らせを待たずに次の 1 枚から全ページへ広がる。
    @Test func turningTheSettingOnWhileTheLookaheadRunsWidensIt() async {
        let log = PrefetchLog()
        let setting = WholeBookSwitch(false)
        let p = make(pageCount: 12, wholeBook: setting, log: log) { relay, page in
            log.fetched(relay, page)
            if page == 2 { setting.on = true }
            return .fetched
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.pages == [1, 2, 3, 4, 5, 6, 10, 11, 9, 0, 7, 8])
    }

    /// 渡した本が無ければ（まだ渡していない・`stop()` の後）、設定の知らせでは何もしない。
    @Test func settingChangeWithoutABookDoesNothing() async {
        let log = PrefetchLog()
        let p = make(pageCount: 5, wholeBook: WholeBookSwitch(true), log: log) { relay, page in
            log.fetched(relay, page)
            return .fetched
        }
        await p.wholeBookSettingChanged()
        await p.waitUntilIdle()
        #expect(log.pages.isEmpty)

        await p.start(relayID: "R", focus: 0)
        await p.stop()
        await p.wholeBookSettingChanged()
        #expect(await p.activeRelayID == nil, "stop() の後は始め直さない")
        #expect(await p.latestRelayID == nil)
    }

    // MARK: - ビューアの要求・止め方（設定 ON で見る）

    /// ビューアがページを頼むと、先読みの中心をそのページへ移す（頼んだページそのものは先読みしない）。
    @Test func aViewerRequestMovesTheCentre() async {
        let log = PrefetchLog()
        let ref = PrefetcherRef()
        let p = make(pageCount: 40, cachedFromLog: true, wholeBook: WholeBookSwitch(true), log: log, ref: ref) { relay, page in
            log.fetched(relay, page)
            if page == 1 {   // 最初の 1 枚を取っているあいだに、ビューアが 20 ページ目を頼んで受け取った
                log.viewerRead(20)
                await ref.value?.liveRequestBegan(relayID: relay, page: 20)
                await ref.value?.liveRequestEnded(relayID: relay)
            }
            return .fetched
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(Array(log.pages.prefix(4)) == [1, 21, 22, 23])
        #expect(!log.pages.contains(20))
        #expect(Set(log.pages) == Set(0..<40).subtracting([20]))
        #expect(log.pages.count == 39, "走っているあいだの要求で終わった後に始め直しても、キャッシュにあるページは取らない")
    }

    /// ビューアの要求が取り中のあいだは、先読みは新しく取りに行かない（待ちを挟み、終わってから続ける）。
    @Test func waitsWhileTheViewerIsFetching() async {
        let log = PrefetchLog()
        let ref = PrefetcherRef()
        let p = make(pageCount: 4, cachedFromLog: true, wholeBook: WholeBookSwitch(true), log: log, ref: ref, sleep: { d in
            log.slept(d)
            if log.sleeps.count == 3 { await ref.value?.liveRequestEnded(relayID: "R") }
        }) { relay, page in
            log.fetched(relay, page)
            if page == 1 { await ref.value?.liveRequestBegan(relayID: relay, page: 1) }
            return .fetched
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.events == ["fetch 1", "sleep", "sleep", "sleep", "fetch 2", "fetch 3", "fetch 0"])
        #expect(log.sleeps.allSatisfy { $0 == .milliseconds(100) })
    }

    /// 別の本を渡すと、前の本の先読みは止まり、新しい本だけを取る。
    @Test func aNewHandOffStopsThePreviousBook() async {
        let log = PrefetchLog()
        let ref = PrefetcherRef()
        let p = make(pageCount: 3, wholeBook: WholeBookSwitch(true), log: log, ref: ref) { relay, page in
            log.fetched(relay, page)
            if relay == "A", page == 1 { await ref.value?.start(relayID: "B", focus: 0) }
            return .fetched
        }
        await p.start(relayID: "A", focus: 0)
        await p.waitUntilIdle()
        #expect(log.pages(of: "A") == [1])
        #expect(log.pages(of: "B") == [1, 2, 0])
        #expect(await p.latestRelayID == "B")
    }

    /// 取り直しても変わらない結果（中継が無い・断られた・版が古い）では、その場で止まる（待ちを挟まない）。
    @Test(arguments: [ViewerRelayPrefetcher.Outcome.relayGone, .refused, .stale])
    func stopsOnOutcomesThatWillNotImprove(_ outcome: ViewerRelayPrefetcher.Outcome) async {
        let log = PrefetchLog()
        let p = make(pageCount: 6, wholeBook: WholeBookSwitch(true), log: log) { relay, page in
            log.fetched(relay, page)
            return page == 2 ? outcome : .fetched
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.pages == [1, 2])
        #expect(log.sleeps.isEmpty)
    }

    /// 中継の記録が無ければ（`plan` が nil）何も取らない。
    @Test func nothingToDoWithoutTheRelay() async {
        let log = PrefetchLog()
        let p = ViewerRelayPrefetcher(
            plan: { _ in nil },
            fetch: { relay, page in log.fetched(relay, page); return .fetched },
            wholeBook: { true }, sleep: { d in log.slept(d) })
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.pages.isEmpty)
    }

    /// 通信の失敗は同じページを 1・2・4・8・16 秒あけて取り直し、6 回目の失敗で諦める。
    @Test func backsOffThenGivesUp() async {
        let log = PrefetchLog()
        let p = make(pageCount: 3, wholeBook: WholeBookSwitch(true), log: log) { relay, page in
            log.fetched(relay, page)
            return .failed
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.pages == [1, 1, 1, 1, 1, 1])
        #expect(log.sleeps == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)])
    }

    /// 取れたら数え直す（間に成功を挟んだ失敗は 1 秒から）。
    @Test func aSuccessResetsTheBackoff() async {
        let log = PrefetchLog()
        let attempts = AttemptCounter()
        let p = make(pageCount: 3, wholeBook: WholeBookSwitch(true), log: log) { relay, page in
            log.fetched(relay, page)
            let n = attempts.next(page)
            // 1 ページ目は 2 回失敗してから取れる。2 ページ目は 1 回失敗してから取れる。
            if page == 1, n <= 2 { return .failed }
            if page == 2, n <= 1 { return .failed }
            return .fetched
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.pages == [1, 1, 1, 2, 2, 0])
        #expect(log.sleeps == [.seconds(1), .seconds(2), .seconds(1)])
    }

    /// 同時に取るのは既定でちょうど 2 枚。最初の 2 枚は、2 枚が同時に走るまで（上限つきで）待たせて、並行度を決まった形で見る。
    @Test func exactlyTwoAtATimeByDefault() async {
        let log = PrefetchLog()
        let gauge = ConcurrencyGauge()
        let calls = AttemptCounter()
        let p = ViewerRelayPrefetcher(
            plan: { _ in (pageCount: 8, cached: []) },
            fetch: { relay, page in
                await gauge.enter()
                if calls.next(-1) <= 2 {
                    var spins = 0
                    while await gauge.entered < 2, spins < 2_000 {
                        spins += 1
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                }
                await gauge.leave()
                log.fetched(relay, page)
                return .fetched
            },
            wholeBook: { true }, sleep: { _ in })
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(await gauge.peak == 2)
        #expect(Set(log.pages) == Set(0..<8))
        #expect(log.pages.count == 8)
    }

    /// `stop()`（口を止めた・終了）で止まり、最後に渡した本も忘れる（版が変わっても先読みし直さない）。
    @Test func stopEndsTheJob() async {
        let log = PrefetchLog()
        let ref = PrefetcherRef()
        let p = make(pageCount: 5, wholeBook: WholeBookSwitch(true), log: log, ref: ref) { relay, page in
            log.fetched(relay, page)
            if page == 1 { await ref.value?.stop() }
            return .fetched
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.pages == [1])
        #expect(await p.latestRelayID == nil)
        await p.versionChanged(relayID: "R")
        await p.waitUntilIdle()
        #expect(log.pages == [1])
    }

    /// 版が変わった（ビューアが manifest を読み直した）とき、最後に渡した本なら新しい版で先読みし直す。ほかの本では何もしない。
    @Test func aVersionChangeRestartsOnlyTheLatestBook() async {
        let log = PrefetchLog()
        let attempts = AttemptCounter()
        let p = make(pageCount: 3, wholeBook: WholeBookSwitch(true), log: log) { relay, page in
            log.fetched(relay, page)
            // 最初の 1 枚は古い版（no-store）で止まる。版が変わった後は取れる。
            return attempts.next(-1) == 1 ? .stale : .fetched
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.pages == [1])
        #expect(await p.stopReason(for: "R") == .stale)
        await p.versionChanged(relayID: "OTHER")
        await p.waitUntilIdle()
        #expect(log.pages == [1])
        await p.versionChanged(relayID: "R")
        #expect(await p.stopReason(for: "R") == nil, "版の変化は止まった理由を解く")
        await p.waitUntilIdle()
        #expect(log.pages == [1, 1, 2, 0])
    }

    // MARK: - 仕事の終わり際（レビュー Important 1）

    /// 仕事の終わり際（最後の 1 枚を選び終えた後・終わる前）にビューアがページを頼んでも、取りこぼさずに
    /// そのページの近傍で始め直す。
    @Test func aViewerRequestAtTheEndOfAJobIsNotLost() async {
        let log = PrefetchLog()
        let ref = PrefetcherRef()
        let once = AttemptCounter()
        let p = make(pageCount: 40, cachedFromLog: true, wholeBook: WholeBookSwitch(false), log: log, ref: ref) { relay, page in
            log.fetched(relay, page)
            return .fetched
        }
        await p.setBeforeFinishForTesting {
            guard once.next(0) == 1 else { return }   // 最初の仕事の終わり際だけ
            log.viewerRead(20)
            await ref.value?.liveRequestBegan(relayID: "R", page: 20)
            await ref.value?.liveRequestEnded(relayID: "R")
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(Array(log.pages.prefix(9)) == [1, 2, 3, 4, 5, 6, 10, 11, 9])
        #expect(Array(log.pages.dropFirst(9)) == [21, 22, 23, 24, 25, 26, 19, 18, 30, 31, 29],
                "終わり際の要求でも、そのページの近傍を取る")
    }

    /// 仕事の終わり際に ON の知らせが届いても、取りこぼさずに全ページの先読みを始める。
    @Test func turningTheSettingOnAtTheEndOfAJobIsNotLost() async {
        let log = PrefetchLog()
        let ref = PrefetcherRef()
        let once = AttemptCounter()
        let setting = WholeBookSwitch(false)
        let p = make(pageCount: 12, cachedFromLog: true, wholeBook: setting, log: log, ref: ref) { relay, page in
            log.fetched(relay, page)
            return .fetched
        }
        await p.setBeforeFinishForTesting {
            guard once.next(0) == 1 else { return }
            setting.on = true
            await ref.value?.wholeBookSettingChanged()
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.pages == [1, 2, 3, 4, 5, 6, 10, 11, 9, 0, 7, 8])
    }

    // MARK: - 取り直しても変わらない理由で止まった後（レビュー Important 2）

    enum TerminalCause: String, Sendable, CaseIterable {
        case refused, stale, gaveUp
    }

    /// 断られた・版が古い・諦めた、で止まった後は、ビューアがページを頼んでも始め直さない（リモートに同じ理由で
    /// 断られるだけ）。止まった理由は中継ごとに覚え、設定が ON になった知らせで解ける。
    @Test(arguments: TerminalCause.allCases)
    func aTerminalStopIsNotRestartedByViewerRequests(_ cause: TerminalCause) async {
        let log = PrefetchLog()
        let healthy = WholeBookSwitch(false)   // リモートが取らせてくれるようになったか
        let setting = WholeBookSwitch(false)
        let p = make(pageCount: 12, cachedFromLog: true, wholeBook: setting, log: log) { relay, page in
            log.fetched(relay, page, stored: healthy.on)
            if healthy.on { return .fetched }
            switch cause {
            case .refused: return .refused
            case .stale: return .stale
            case .gaveUp: return .failed
            }
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        let expected: ViewerRelayPrefetcher.StopReason = switch cause {
        case .refused: .refused
        case .stale: .stale
        case .gaveUp: .gaveUp
        }
        #expect(await p.stopReason(for: "R") == expected)
        let attempts = log.pages.count
        #expect(attempts == (cause == .gaveUp ? 6 : 1))

        // ビューアがページを頼んでも（何度でも）、先読みはリモートへ行かない。
        for page in [5, 6] {
            log.viewerRead(page)
            await p.liveRequestBegan(relayID: "R", page: page)
            await p.liveRequestEnded(relayID: "R")
            await p.waitUntilIdle()
        }
        #expect(log.pages.count == attempts)
        #expect(await p.activeRelayID == nil)
        #expect(await p.stopReason(for: "R") == expected)

        // ON の知らせで解ける（取れるようになっていれば全ページが入る）。
        healthy.on = true
        setting.on = true
        await p.wholeBookSettingChanged()
        await p.waitUntilIdle()
        #expect(await p.stopReason(for: "R") == nil)
        #expect(log.cached == Set(0..<12))
    }

    /// 止まった理由は、版の変化（`versionChanged`）と渡し直し（`start`）でも解ける。
    @Test func aVersionChangeOrANewHandOffClearsTheStopReason() async {
        let log = PrefetchLog()
        let healthy = WholeBookSwitch(false)
        let p = make(pageCount: 3, wholeBook: WholeBookSwitch(true), log: log) { relay, page in
            log.fetched(relay, page, stored: healthy.on)
            return healthy.on ? .fetched : .refused
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(await p.stopReason(for: "R") == .refused)
        healthy.on = true
        await p.versionChanged(relayID: "R")
        await p.waitUntilIdle()
        #expect(await p.stopReason(for: "R") == nil)
        #expect(log.pages(of: "R") == [1, 1, 2, 0])

        healthy.on = false
        await p.start(relayID: "B", focus: 0)
        await p.waitUntilIdle()
        #expect(await p.stopReason(for: "B") == .refused)
        healthy.on = true
        await p.start(relayID: "B", focus: 0)   // 同じ本を渡し直した
        #expect(await p.stopReason(for: "B") == nil)
        await p.waitUntilIdle()
        #expect(log.pages(of: "B") == [1, 1, 2, 0])
    }

    // MARK: - 補強（レビュー）

    /// 2 本のとき、断られたら両方の worker が止まる（取り中の分のほかは取らない）。
    @Test func aRefusalStopsBothWorkers() async {
        let log = PrefetchLog()
        let p = make(pageCount: 30, wholeBook: WholeBookSwitch(true), concurrency: 2, log: log) { relay, page in
            log.fetched(relay, page)
            if page == 2 { return .refused }
            try? await Task.sleep(for: .milliseconds(20))
            return .fetched
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.pages.count <= 3, "断られた後は、取り中の分のほかは取らない")
        #expect(await p.activeRelayID == nil)
        #expect(await p.stopReason(for: "R") == .refused)
    }

    /// 仕事が走っているあいだにビューアが頼んでも、その仕事が断られて止まったなら、終わり際に始め直さない。
    @Test func aPendingRestartDoesNotOverrideAStopReason() async {
        let log = PrefetchLog()
        let ref = PrefetcherRef()
        let p = make(pageCount: 12, cachedFromLog: true, wholeBook: WholeBookSwitch(true), log: log, ref: ref) { relay, page in
            log.fetched(relay, page, stored: false)
            if page == 1 {
                await ref.value?.liveRequestBegan(relayID: relay, page: 3)
                await ref.value?.liveRequestEnded(relayID: relay)
            }
            return .refused
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.pages == [1])
        #expect(await p.stopReason(for: "R") == .refused)
    }

    /// 中継が無くなった（`relayGone`）ときは、止まるが理由は残さない。
    @Test func relayGoneLeavesNoStopReason() async {
        let log = PrefetchLog()
        let p = make(pageCount: 6, wholeBook: WholeBookSwitch(true), log: log) { relay, page in
            log.fetched(relay, page)
            return page == 2 ? .relayGone : .fetched
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.pages == [1, 2])
        #expect(await p.stopReason(for: "R") == nil)
    }

    /// ほかの中継のビューアの要求も、先読みを止める（数はどの中継のものでも数える）。
    @Test func aViewerRequestOnAnotherRelayPausesThePrefetch() async {
        let log = PrefetchLog()
        let ref = PrefetcherRef()
        let p = make(pageCount: 4, cachedFromLog: true, wholeBook: WholeBookSwitch(true), log: log, ref: ref, sleep: { d in
            log.slept(d)
            if log.sleeps.count == 2 { await ref.value?.liveRequestEnded(relayID: "OTHER") }
        }) { relay, page in
            log.fetched(relay, page)
            if page == 1 { await ref.value?.liveRequestBegan(relayID: "OTHER", page: 9) }
            return .fetched
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.events == ["fetch 1", "sleep", "sleep", "fetch 2", "fetch 3", "fetch 0"])
    }

    /// 仕事の始めの `plan` を待っているあいだにビューアが頼んだページは、先読みしない
    /// （`plan` の答えのキャッシュにはまだ入っていない）。
    @Test func aViewerRequestDuringPlanKeepsThatPageOut() async {
        let log = PrefetchLog()
        let gate = TestGate()
        let planCalls = AttemptCounter()
        let p = ViewerRelayPrefetcher(
            tuning: .init(concurrency: 1),
            plan: { _ in
                let n = planCalls.next(0)
                if n == 1 { await gate.wait() }
                // 1 回目の答えは、ビューアが取る前のキャッシュ。始め直した 2 回目は、ビューアが取った後。
                return (pageCount: 6, cached: n == 1 ? log.cached : log.cached.union([3]))
            },
            fetch: { relay, page in log.fetched(relay, page); return .fetched },
            wholeBook: { true }, sleep: { _ in })
        await p.start(relayID: "R", focus: 0)
        await p.liveRequestBegan(relayID: "R", page: 3)
        await p.liveRequestEnded(relayID: "R")
        await gate.open()
        await p.waitUntilIdle()
        #expect(!log.pages.contains(3))
        #expect(log.pages.count == Set(log.pages).count)
    }

    // MARK: - 失敗の取り直しはページごと

    /// 1 枚だけ取れないページがあっても、ほかが取れているあいだは仕事を止めない。そのページは 1・2・4・8・16 秒あけて
    /// 6 回取り、諦めて外す（ほかのページは 1 回ずつ取る）。待ちの前に、ほかの worker が取れたことを仕事の側の数で確かめる。
    @Test(.timeLimit(.minutes(1))) func aSinglePageThatNeverFetchesIsDroppedNotTheJob() async {
        let log = PrefetchLog()
        let ref = PrefetcherRef()
        let broken = 3
        let tries = AttemptCounter()
        let p = ViewerRelayPrefetcher(
            tuning: .init(concurrency: 2),
            plan: { _ in (pageCount: 6, cached: []) },
            fetch: { relay, page in
                if page == broken {
                    if tries.next(page) == 1 {
                        // 最初の失敗の前に、ほかのページが 1 枚取れて仕事に数えられているのを待つ。
                        var spins = 0
                        while await ref.value?.successesForTesting() ?? 0 < 1, spins < 100_000 {
                            spins += 1
                            await Task.yield()
                        }
                    }
                    log.fetched(relay, page, stored: false)
                    return .failed
                }
                log.fetched(relay, page)
                return .fetched
            },
            wholeBook: { true },
            sleep: { d in
                log.slept(d)
                // 最初の失敗の後に、ほかのページがもう 1 枚取れたと仕事に数えられるまで待つ。
                var spins = 0
                while await ref.value?.successesForTesting() ?? 0 < 2, spins < 100_000 {
                    spins += 1
                    await Task.yield()
                }
            })
        ref.value = p
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(log.pages.filter { $0 == broken }.count == 6)
        #expect(log.sleeps == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)])
        for page in [0, 1, 2, 4, 5] {
            #expect(log.pages.filter { $0 == page }.count == 1, "page \(page)")
        }
        #expect(await p.stopReason(for: "R") == nil)
        #expect(await p.activeRelayID == nil)
    }

    /// 2 本で全部が取れないなら（通信が落ちている）、諦めて止まる。1 ページが 6 回を超えて取られることはない。
    @Test func everythingFailingWithTwoWorkersGivesUp() async {
        let log = PrefetchLog()
        let p = make(pageCount: 20, wholeBook: WholeBookSwitch(true), concurrency: 2, log: log) { relay, page in
            log.fetched(relay, page, stored: false)
            return .failed
        }
        await p.start(relayID: "R", focus: 0)
        await p.waitUntilIdle()
        #expect(await p.stopReason(for: "R") == .gaveUp)
        for page in Set(log.pages) {
            #expect(log.pages.filter { $0 == page }.count <= 6, "page \(page)")
        }
        #expect(log.pages.count <= 12)
        #expect(log.pages.count >= 6)
    }
}

/// 開くまで待たせる門。
actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
