// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G62（spec §6.3・§8）: 反映の間隔の決め方（偽の時計＝こちらが渡す時刻で確かめる）。
@Suite("G62: FlushThrottle")
struct FlushThrottleTests {
    private let t0 = ContinuousClock.now
    private func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

    @Test func quietTimeFlushesAtOnce() {
        var t = FlushThrottle(interval: .milliseconds(250))
        #expect(t.noteArrived(at: at(0)) == .flushNow)
    }

    @Test func notesInsideTheIntervalCollapseIntoOneScheduledFlush() {
        var t = FlushThrottle(interval: .milliseconds(250))
        #expect(t.noteArrived(at: at(0)) == .flushNow)
        #expect(t.flushFinished(at: at(10), hasPending: false) == nil)
        #expect(t.noteArrived(at: at(50)) == .flushAfter(.milliseconds(210)))
        #expect(t.noteArrived(at: at(60)) == .coalesced)
        #expect(t.noteArrived(at: at(200)) == .coalesced)
        t.scheduledFlushBegins()
        #expect(t.flushFinished(at: at(265), hasPending: false) == nil)
        // 間隔を過ぎた後の 1 件は、またすぐ
        #expect(t.noteArrived(at: at(600)) == .flushNow)
    }

    @Test func arrivalsDuringAFlushGoToTheNextRound() {
        var t = FlushThrottle(interval: .milliseconds(250))
        #expect(t.noteArrived(at: at(0)) == .flushNow)
        #expect(t.noteArrived(at: at(1)) == .coalesced)
        #expect(t.flushFinished(at: at(5), hasPending: true) == .flushAfter(.milliseconds(250)))
        #expect(t.noteArrived(at: at(6)) == .coalesced)
    }

    /// 後ろ側のデバウンスではない: 20 ms ごとに通知が途切れなく来ても、間隔ごとに反映する。
    @Test func aContinuousStreamStillFlushesEveryInterval() {
        var t = FlushThrottle(interval: .milliseconds(250))
        var starts: [Int] = []
        var dueAt: Int?
        var pending = false
        func finish(at ms: Int) {
            if case .flushAfter(let wait)? = t.flushFinished(at: at(ms + 5), hasPending: pending) {
                dueAt = ms + 5 + Int(wait / .milliseconds(1))
            }
        }
        for ms in stride(from: 0, through: 2_000, by: 10) {
            if let due = dueAt, ms >= due {
                t.scheduledFlushBegins()
                dueAt = nil
                starts.append(ms)
                pending = false
                finish(at: ms)
            }
            if ms.isMultiple(of: 20) {
                pending = true
                switch t.noteArrived(at: at(ms)) {
                case .flushNow:
                    starts.append(ms)
                    pending = false
                    finish(at: ms)
                case .flushAfter(let wait):
                    dueAt = ms + Int(wait / .milliseconds(1))
                case .coalesced:
                    break
                }
            }
        }
        #expect(starts.count >= 7, Comment(rawValue: "\(starts)"))
        for (a, b) in zip(starts, starts.dropFirst()) {
            #expect(b - a >= 250 && b - a <= 270, Comment(rawValue: "\(starts)"))
        }
    }
}
