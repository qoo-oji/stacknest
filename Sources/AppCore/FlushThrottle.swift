// SPDX-License-Identifier: MIT
import Foundation

/// G62（spec §6.3）: 外部の変更を画面へ反映する間隔を決める（純粋な値。時刻は呼び出し側が渡す）。
///
/// - 静かなとき（前の反映が終わってから `interval` 以上たった）は**すぐ**反映する。
/// - そうでなければ「前の反映の終わり＋`interval`」に 1 回だけ予約する。後から来た通知で予約を延ばさない
///   （後ろ側のデバウンスにしない）ので、通知が途切れなくても `interval` ごとに反映は進む。
/// - 反映は 1 度に 1 つ。反映の最中に来た通知は、終わった時点で次の回を予約する。
public struct FlushThrottle: Sendable {
    public enum Decision: Equatable, Sendable {
        /// 今すぐ反映を始める。
        case flushNow
        /// この時間の後に反映を始める（待ってから `scheduledFlushBegins()` を呼び、反映する）。
        case flushAfter(Duration)
        /// 反映が走っているか予約済み。貯めておけば次の回に入る。
        case coalesced
    }

    public let interval: Duration
    private var lastFlushEnd: ContinuousClock.Instant?
    private var isFlushing = false
    private var isScheduled = false

    public init(interval: Duration) {
        self.interval = interval
    }

    /// 通知が 1 件届いた。
    public mutating func noteArrived(at now: ContinuousClock.Instant) -> Decision {
        if isFlushing || isScheduled { return .coalesced }
        if let last = lastFlushEnd, now < last + interval {
            isScheduled = true
            return .flushAfter(now.duration(to: last + interval))
        }
        isFlushing = true
        return .flushNow
    }

    /// 予約した反映を始める。
    public mutating func scheduledFlushBegins() {
        isScheduled = false
        isFlushing = true
    }

    /// 反映が終わった。まだ貯まっていれば、次の回の予約を返す。
    public mutating func flushFinished(at now: ContinuousClock.Instant, hasPending: Bool) -> Decision? {
        isFlushing = false
        lastFlushEnd = now
        guard hasPending else { return nil }
        isScheduled = true
        return .flushAfter(interval)
    }
}
