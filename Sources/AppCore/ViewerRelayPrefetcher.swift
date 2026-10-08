// SPDX-License-Identifier: MIT
import Foundation

/// G60 §5.9（2026-10-08 作者の決定）: 外部ビューアに渡したリモートの本を、裏で先読みしてキャッシュに入れる。
///
/// ここは「どの順に・どこまで・いつまで取るか」だけを持つ。取り方（中継自身の道でリモートから取り、キャッシュに入れる）と
/// 設定の読み方は、LibraryServer の中継が閉包で渡す（`ViewerRelayConfig`）。
/// - 範囲は内蔵ビューアと同じ設定「開いた本を全ページ先読みする」（`wholeBook()`）に従い、取るページを 1 枚選ぶたびに読む:
///   ON＝全ページ・OFF＝内蔵と同じ近傍だけ（`PrefetchPlanner.plan(tier3: wholeBook())`）。
/// - 中心はビューアが最後に頼んだページ（渡した時点は開くページ）、向きは内蔵の `navDirection` と同じ考え方。
/// - 同時に走る仕事は 1 冊（最後に渡した本）。`start` は前の仕事を止める。取るページが無くなったら仕事は終わり、
///   ビューアが次にページを頼んだとき（または設定が ON になった知らせで）始め直す。
/// - ビューアの要求が取り中のあいだ（`liveRequestBegan`〜`liveRequestEnded`）は新しく取りに行かない。
/// - 1 冊ごとの量の上限は無い（あふれた分はキャッシュ自身の上限の退避が消す）。
/// - 止まる: 取るページが無い・中継が無い・断られた・版が古い・通信の失敗が続いた・`stop()`。
///   断られた・版が古い・諦めたときは理由を中継ごとに覚え、ビューアの要求では始め直さない（`StopReason`）。
/// - 仕事が走っているあいだに届いた始め直しの頼み（ビューアの要求・ON の知らせ）は、仕事の終わり（`finish`）で使う
///   （最後の 1 枚を選び終えてから終わるまでのあいだに届いた頼みを取りこぼさない）。
public actor ViewerRelayPrefetcher {
    /// 1 ページを取った結果（取り方の側が決める）。
    public enum Outcome: Sendable, Equatable {
        /// リモートから取ってキャッシュに入れた。
        case fetched
        /// 既にキャッシュにあった（取りに行っていない）。
        case alreadyCached
        /// リモートが `no-store` で返した（中継の版が古い）。入れていない。
        case stale
        /// リモートが断った（401・403・404・410）。取り直しても同じ。
        case refused
        /// 届かない・時間切れ・5xx など。間をあけて取り直す。
        case failed
        /// 中継の記録が無い（StackNest の終了・期限切れ）。
        case relayGone
    }

    public struct Tuning: Sendable {
        /// 同時に取る枚数。
        public var concurrency: Int
        /// 通信の失敗が続いたときに、次を取るまで待つ時間（使い切ったら諦める）。
        public var backoff: [Duration]
        /// ビューアの要求が終わるのを見る間隔。
        public var livePollInterval: Duration

        public init(concurrency: Int = 2,
                    backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)],
                    livePollInterval: Duration = .milliseconds(100)) {
            self.concurrency = concurrency
            self.backoff = backoff
            self.livePollInterval = livePollInterval
        }
    }

    /// 取り直しても変わらない理由で止まったときの理由（中継ごとに覚える）。これがあるあいだは、ビューアが
    /// ページを頼んでも始め直さない（リモートに同じ理由で断られるだけ）。`start`（渡し直し）・`versionChanged`
    /// （manifest の読み直し）・設定が ON になった知らせで解く。
    public enum StopReason: Sendable, Equatable {
        /// リモートが断った（401・403・404・410）。
        case refused
        /// リモートが `no-store` で返した（中継の版が古い）。
        case stale
        /// 通信の失敗が続き、間をあけた取り直しを使い切った。
        case gaveUp
    }

    /// 仕事の始めに引く: その中継のページ数と、キャッシュにあるページ。中継が無ければ nil。
    public typealias Plan = @Sendable (_ relayID: String) async -> (pageCount: Int, cached: Set<Int>)?
    /// 1 ページを取る。
    public typealias Fetch = @Sendable (_ relayID: String, _ page: Int) async -> Outcome
    /// 内蔵の「開いた本を全ページ先読みする」（`remote_prefetch_whole_book`）が今 ON か。取るページを選ぶたびに読む。
    public typealias WholeBook = @Sendable () -> Bool
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private struct Job {
        let relayID: String
        let generation: Int
        var pageCount = 0
        var remaining: Set<Int> = []
        var failures = 0
        var task: Task<Void, Never>?
    }

    private let tuning: Tuning
    private let plan: Plan
    private let fetch: Fetch
    private let wholeBook: WholeBook
    private let sleep: Sleep
    private var job: Job?
    private var generation = 0
    /// 最後に渡した本の中継（`stop()` で忘れる）。始め直す相手。
    public private(set) var latestRelayID: String?
    /// 先読みの中心（ビューアが最後に頼んだページ。渡した時点は開くページ）。
    private var latestFocus = 0
    /// 進む向き（+1 / -1）。内蔵の `navDirection` と同じ考え方。
    private var latestDirection = 1
    /// ビューアの要求で取り中の数（どの中継のものでも数える）。
    private var liveRequests = 0
    /// 止まった理由（中継ごと）。
    private var stopReasons: [String: StopReason] = [:]
    /// 仕事が走っているあいだに届いた始め直しの頼み（ビューアの要求・ON の知らせ）。仕事の終わり（`finish`）で使う。
    private var pendingRestart = false
    /// テスト用: `run` が `finish` を呼ぶ直前に呼ぶ（仕事の終わり際を作る）。
    private var beforeFinish: (@Sendable () async -> Void)?

    public init(tuning: Tuning = Tuning(), plan: @escaping Plan, fetch: @escaping Fetch,
                wholeBook: @escaping WholeBook, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.tuning = tuning
        self.plan = plan
        self.fetch = fetch
        self.wholeBook = wholeBook
        self.sleep = sleep
    }

    /// 今走っている仕事の中継（無ければ nil）。
    public var activeRelayID: String? { job?.relayID }

    /// その中継が止まった理由（止まっていなければ nil）。
    public func stopReason(for relayID: String) -> StopReason? { stopReasons[relayID] }

    /// テスト用: 仕事の終わり際（最後の 1 枚を選び終えた後・`finish` の前）に呼ぶ処理を差し込む。
    func setBeforeFinishForTesting(_ hook: (@Sendable () async -> Void)?) { beforeFinish = hook }

    /// 渡した本の先読みを始める。前の仕事（別の本・同じ本）は止める。`focus` は開くページ。
    public func start(relayID: String, focus: Int) {
        latestRelayID = relayID
        latestFocus = max(0, focus)
        latestDirection = 1
        // 渡し直し: 前の止まった理由は持ち越さない（仕事を持つのは最後に渡した本だけ）。
        stopReasons.removeAll()
        startJob(for: relayID)
    }

    /// 止める（127.0.0.1 の口を止めた・StackNest の終了）。最後に渡した本も忘れる。
    /// 取り中の分は取り方の側（`ViewerRelayPageLoader`）で最後まで走ってキャッシュに入る。
    public func stop() {
        job?.task?.cancel()
        job = nil
        latestRelayID = nil
        pendingRestart = false
    }

    /// ビューアの manifest で版（またはページ数）が変わった。最後に渡した本なら、新しい版で先読みし直す。
    /// 止まった理由（版が古い・断られた）があっても解く（新しい版なら取れるかもしれない）。
    public func versionChanged(relayID: String) {
        guard relayID == latestRelayID else { return }
        stopReasons[relayID] = nil
        startJob(for: relayID)
    }

    /// 「開いた本を全ページ先読みする」が切り替わった（設定の画面の知らせ）。ON なら、最後に渡した本の止まった理由を解き、
    /// 仕事が走っていなければ（近傍を取り終えた後など）すぐ始め直す。走っていれば次の 1 枚から全ページへ広がるが、
    /// 終わり際（最後の 1 枚を選び終えた後）に届いた知らせを取りこぼさないよう、終わったら始め直す頼みも残す。
    /// OFF は何もしない（走っている仕事は次の 1 枚から近傍だけに戻り、取り中の分は最後まで取る）。
    public func wholeBookSettingChanged() {
        guard wholeBook(), let relayID = latestRelayID else { return }
        stopReasons[relayID] = nil
        if job != nil {
            pendingRestart = true
        } else {
            startJob(for: relayID)
        }
    }

    /// ビューアがページを頼んだ（取り終わるまで先読みは新しく取りに行かない）。最後に渡した本なら中心と向きを
    /// そのページへ移し、そのページは先読みしない。仕事が終わっていたら、そのページを中心に始め直す
    /// （設定が OFF なら、内蔵ビューアがページを移るたびに近傍を取り直すのと同じ）。ただし止まった理由があれば
    /// 始め直さない。仕事が走っていれば、終わり際の取りこぼしを防ぐため、終わったら始め直す頼みを残す。
    public func liveRequestBegan(relayID: String, page: Int) {
        liveRequests += 1
        guard relayID == latestRelayID else { return }
        if page < latestFocus {
            latestDirection = -1
        } else if page > latestFocus {
            latestDirection = 1
        }
        latestFocus = max(0, page)
        if job != nil {
            job?.remaining.remove(page)
            pendingRestart = true
        } else if stopReasons[relayID] == nil {
            startJob(for: relayID)
        }
    }

    /// ビューアの要求が終わった。
    public func liveRequestEnded(relayID: String) {
        if liveRequests > 0 { liveRequests -= 1 }
    }

    /// 今の仕事と、そのあいだに始まった仕事が終わるまで待つ（テスト用）。
    public func waitUntilIdle() async {
        while let task = job?.task {
            await task.value
            if job?.task == task { job = nil }
        }
    }

    // MARK: - 内部

    private func startJob(for relayID: String) {
        job?.task?.cancel()
        pendingRestart = false
        generation += 1
        let gen = generation
        var next = Job(relayID: relayID, generation: gen)
        next.task = Task { await self.run(gen) }
        job = next
    }

    private func run(_ gen: Int) async {
        guard let relayID = job?.relayID, job?.generation == gen else { return }
        let snapshot = await plan(relayID)
        guard job?.generation == gen, !Task.isCancelled else { return }
        guard let snapshot, snapshot.pageCount > 0 else {
            finish(gen)
            return
        }
        job?.pageCount = snapshot.pageCount
        job?.remaining = Set(0..<snapshot.pageCount).subtracting(snapshot.cached)
        let workers = max(1, tuning.concurrency)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask { await self.work(gen) }
            }
        }
        if let beforeFinish { await beforeFinish() }
        finish(gen)
    }

    /// 仕事を終える。走っているあいだに届いた頼み（ビューアの要求・ON の知らせ）があれば、その時点の中心と設定で
    /// 始め直す（終わり際に届いた頼みを取りこぼさない）。止まった理由があるとき（断られた・版が古い・諦めた）は始め直さない。
    private func finish(_ gen: Int) {
        guard let current = job, current.generation == gen else { return }
        job = nil
        let rerun = pendingRestart
        pendingRestart = false
        if rerun, current.relayID == latestRelayID, stopReasons[current.relayID] == nil {
            startJob(for: current.relayID)
        }
    }

    private func work(_ gen: Int) async {
        while !Task.isCancelled {
            // ビューアの要求が取り中のあいだは、新しく取りに行かない（取り消されたら待ちをやめる。
            // テストの `sleep` は取り消しで投げないので、条件でも見る）。
            while isLive(gen), !Task.isCancelled {
                do { try await sleep(tuning.livePollInterval) } catch { return }
            }
            guard let pick = next(gen) else { return }
            let outcome = await fetch(pick.relayID, pick.page)
            guard let pause = record(outcome, page: pick.page, gen: gen) else { return }
            if pause > .zero {
                do { try await sleep(pause) } catch { return }
            }
        }
    }

    private func isLive(_ gen: Int) -> Bool {
        guard let job, job.generation == gen else { return false }
        return liveRequests > 0
    }

    /// 次に取るページ。**設定をここで毎回読む**: ON なら全ページ（tier3）、OFF なら内蔵と同じ近傍だけの順で、
    /// 残っている最初のもの。仕事が替わった・残りが無い・選べるページが無い（OFF で近傍を取り終えた）なら nil。
    private func next(_ gen: Int) -> (relayID: String, page: Int)? {
        guard var current = job, current.generation == gen, !current.remaining.isEmpty else { return nil }
        let order = PrefetchPlanner.plan(current: latestFocus, pageCount: current.pageCount, spreadPages: nil,
                                         tier3: wholeBook(), direction: latestDirection).queue
        guard let page = order.first(where: { current.remaining.contains($0) }) else { return nil }
        current.remaining.remove(page)
        job = current
        return (current.relayID, page)
    }

    /// 結果を反映し、次を取る前に待つ時間を返す（nil なら仕事を止める）。
    private func record(_ outcome: Outcome, page: Int, gen: Int) -> Duration? {
        guard job?.generation == gen else { return nil }
        switch outcome {
        case .fetched:
            job?.failures = 0
            return .zero
        case .alreadyCached:
            return .zero
        case .failed:
            job?.remaining.insert(page)
            let failures = (job?.failures ?? 0) + 1
            job?.failures = failures
            guard failures <= tuning.backoff.count else {
                stopJob(gen, reason: .gaveUp)
                return nil
            }
            return tuning.backoff[failures - 1]
        case .stale:
            stopJob(gen, reason: .stale)
            return nil
        case .refused:
            stopJob(gen, reason: .refused)
            return nil
        case .relayGone:
            stopJob(gen, reason: nil)
            return nil
        }
    }

    /// 仕事を取り消す（記録は `run` の終わりの `finish` で消える）。理由があれば中継ごとに覚える
    /// （ビューアの要求では始め直さない）。
    private func stopJob(_ gen: Int, reason: StopReason?) {
        guard let current = job, current.generation == gen else { return }
        if let reason { stopReasons[current.relayID] = reason }
        current.task?.cancel()
    }
}
