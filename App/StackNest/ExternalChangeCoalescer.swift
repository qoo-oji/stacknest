// SPDX-License-Identifier: MIT
import Foundation
import Synchronization
import AppCore
import LibraryServerAPI

/// G62（spec §6.3）: 両方のサーバ（ローカルコントロール・共有サーバ）の「本が変わった」「一覧の構造が変わった」を
/// 書庫ごとに貯め、`FlushThrottle` の決めた間隔（既定 250 ms・Q2 (b)）ごとに **MainActor へ 1 回だけ**入って反映する。
/// 通知 1 件ごとに MainActor の Task を作っていたのを置き換える（連続の書き込みで MainActor が埋まっていた）。
///
/// - 最初の 1 件はすぐ、続く分は間隔ごとに 1 回。後ろ側のデバウンスではないので、通知が途切れなくても反映は止まらない。
/// - 反映は 1 度に 1 つ。反映の最中に来た通知は次の回に入る。
/// - 共有サーバへの橋渡し（`publishLiveEvent`）は今と同じく**ローカルコントロール発の分だけ**、届いた順・同じ数で、
///   反映の後に出す（遅れは間隔まで）。
/// - 捨てるのは、反映の前にその書庫が閉じたときだけ（`applyExternalChanges` が何もしない）。
final class ExternalChangeCoalescer: Sendable {
    enum Origin: Sendable {
        case localControl
        case sharedServer
    }

    /// 書庫 1 つ分の、まだ反映していない変更。
    struct Batch: Equatable, Sendable {
        var bookIDs: Set<Int> = []
        var structureChanged = false
        /// 共有サーバの EventHub へ橋渡しするイベント（ローカルコントロール発のものだけ・届いた順）。
        var bridged: [LiveEvent] = []
    }

    typealias Deliver = @MainActor @Sendable ([String: Batch]) -> Void

    /// 本番の 1 つ。両方のコントローラのクロージャがこれを呼ぶ。
    static let shared = ExternalChangeCoalescer(interval: .milliseconds(250), deliver: { batches in
        ExternalChangeCoalescer.deliver(batches, to: AppState.activeInstances.allObjects,
                                        bridge: { ServerController.shared.publishLiveEvent($0) })
    })

    private struct State {
        var throttle: FlushThrottle
        var pending: [String: Batch] = [:]
    }

    private let state: Mutex<State>
    private let deliverBatches: Deliver
    private let sleep: @Sendable (Duration) async -> Void

    init(interval: Duration, deliver: @escaping Deliver,
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.state = Mutex(State(throttle: FlushThrottle(interval: interval)))
        self.deliverBatches = deliver
        self.sleep = sleep
    }

    /// 本 1 冊のメタデータが変わった（`LibraryServerConfig.onBookChanged`）。どのスレッドからでも呼べる。
    func note(book bookID: Int, in library: String, origin: Origin) {
        enqueue(library) { batch in
            batch.bookIDs.insert(bookID)
            if origin == .localControl { batch.bridged.append(.bookChanged(library: library, bookID: bookID)) }
        }
    }

    /// 一覧の行の集合が変わった（`LibraryServerConfig.onLibraryStructureChanged`）。どのスレッドからでも呼べる。
    func noteStructure(in library: String, origin: Origin) {
        enqueue(library) { batch in
            batch.structureChanged = true
            if origin == .localControl { batch.bridged.append(.structureChanged(library: library)) }
        }
    }

    private func enqueue(_ library: String, _ change: (inout Batch) -> Void) {
        let decision = state.withLock { s -> FlushThrottle.Decision in
            change(&s.pending[library, default: Batch()])
            return s.throttle.noteArrived(at: .now)
        }
        start(decision)
    }

    private func start(_ decision: FlushThrottle.Decision) {
        switch decision {
        case .coalesced:
            return
        case .flushNow:
            Task { await self.flush() }
        case .flushAfter(let wait):
            Task {
                await self.sleep(wait)
                self.state.withLock { $0.throttle.scheduledFlushBegins() }
                await self.flush()
            }
        }
    }

    /// 貯まった分を全部取り出し、MainActor で 1 回だけ反映する。終わったら、その間に貯まった分の次の回を予約する。
    private func flush() async {
        let batches = state.withLock { s -> [String: Batch] in
            let taken = s.pending
            s.pending = [:]
            return taken
        }
        if !batches.isEmpty {
            await deliverBatches(batches)
        }
        let next = state.withLock { s in
            s.throttle.flushFinished(at: .now, hasPending: !s.pending.isEmpty)
        }
        if let next { start(next) }
    }

    /// 本番の反映（テストは `to:` と `bridge:` を差し替える）。書庫ごとに、その書庫を開いている AppState へ 1 回だけ入れ、
    /// 続けて共有サーバへ橋渡しする。
    @MainActor
    static func deliver(_ batches: [String: Batch], to states: [AppState], bridge: (LiveEvent) -> Void) {
        for (uuid, batch) in batches {
            for state in states where state.librarySettings?.libraryUUID == uuid {
                state.applyExternalChanges(bookIDs: batch.bookIDs, structureChanged: batch.structureChanged)
            }
            for event in batch.bridged { bridge(event) }
        }
    }
}
