// SPDX-License-Identifier: MIT
import Foundation
import LibraryServerAPI

/// G62b: イベントの対象書庫を、このハブがどう扱うか。
public enum LiveEventLibraryState: Sendable, Equatable {
    /// データソースが配信していない（共有 OFF・共有したことがない・閉じた）。イベントは送らない。
    case unserved
    /// 配信中・無施錠。そのまま送る。
    case unlocked
    /// 配信中・施錠（または施錠の状態を読めない）。`bookChanged` を丸めて送る。
    case locked
}

/// SSE 購読者へライブイベントを配信するハブ。購読ごとに scope を保持し、
/// publish 時に scope.allows(event.library) を満たす購読者にのみ yield する。
/// G62b: 配信していない書庫のイベントは、scope にかかわらず誰にも送らない。
public actor EventHub {
    private struct Subscriber {
        let scope: GrantScope
        let continuation: AsyncStream<LiveEvent>.Continuation
    }
    private var subscribers: [UUID: Subscriber] = [:]
    /// G23 (#15)・G62b: 対象ライブラリを配信しているか・施錠中かを問い合わせる。
    /// 配信していなければ送らず、施錠庫のイベントは粒度を落として配信する（下記 `coarsenIfLocked`）。
    /// 判定は `LibraryResolver.resolve` と同じデータソース（`servedLibraries()`）に拠る。
    private let libraryState: @Sendable (String) async -> LiveEventLibraryState

    /// 既定は「すべて配信中・無施錠」（データソースを持たない単体テスト用）。
    public init(libraryState: @escaping @Sendable (String) async -> LiveEventLibraryState = { _ in .unlocked }) {
        self.libraryState = libraryState
    }

    /// G23 の形（施錠だけを問う）。すべての書庫を配信中として扱う（単体テスト用）。
    public init(isLibraryLocked: @escaping @Sendable (String) async -> Bool) {
        self.libraryState = { await isLibraryLocked($0) ? .locked : .unlocked }
    }

    public func subscribe(scope: GrantScope) -> (id: UUID, stream: AsyncStream<LiveEvent>) {
        let id = UUID()
        let stream = AsyncStream<LiveEvent> { continuation in
            subscribers[id] = Subscriber(scope: scope, continuation: continuation)
        }
        return (id, stream)
    }

    /// G23 (#15): 施錠判定のため `async` になった。
    ///
    /// この `await` は actor のサスペンドポイントなので、判定を待つ間に別の `publish` が
    /// 割り込み、**配信順序が publish 順と入れ替わりうる**。クライアントは個々のイベントを
    /// 差分適用するのではなく「変更があった」ことを合図にデバウンス付きで再取得する設計
    /// （web は `livesync.js` の `scheduleReload`）なので、順序が入れ替わっても最終状態は
    /// 同じところへ収束する。順序に意味を持たせるイベントを追加する場合はここを見直すこと。
    ///
    /// G62b: 書庫に紐づくイベント（`.connected` 以外のすべて）は、対象書庫を今配信していなければ落とす。
    /// 以前は scope だけで絞っていたため、scope `.all` の購読者に共有していない書庫の UUID・本の ID・
    /// 編集の時刻が流れ、施錠して共有していた書庫の共有を切ると丸めも外れていた。
    /// App の全 publisher（`ServerController.publishLiveEvent`）、コアの更新系の道、共有のメンテナンス
    /// fanout のどれもこの関数を通るので、ここ 1 か所で全部を覆う。
    public func publish(_ event: LiveEvent) async {
        if case .connected = event { return }   // サーバは emit しない（クライアント合成）
        let state = await libraryState(event.library)
        guard state != .unserved else { return }
        let delivered = coarsenIfLocked(event, state: state)
        for sub in subscribers.values where sub.scope.allows(delivered.library) {
            sub.continuation.yield(delivered)
        }
    }

    /// G23 (#15): 施錠庫の `bookChanged` は `bookID` を落として `structureChanged` に丸める。
    ///
    /// `bookID` は連番のため、未解錠のクライアントに流れると蔵書数の概算が漏れる。
    /// 配信自体は止めない — 止めると解錠して見ている最中もライブ同期が効かず手動リロードが要る。
    /// 丸めても実害はない: クライアントは「変わった」と知って再取得し、その取得は
    /// `LibraryResolver.resolve` のロック判定を通るため、未解錠なら 403 で弾かれる。
    private func coarsenIfLocked(_ event: LiveEvent, state: LiveEventLibraryState) -> LiveEvent {
        guard case .bookChanged(let library, _) = event else { return event }
        return state == .locked ? .structureChanged(library: library) : event
    }

    public func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.continuation.finish()
    }
}
