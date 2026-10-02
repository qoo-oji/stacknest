// SPDX-License-Identifier: MIT
import Foundation

/// G60 v3（spec §5.8・試用）: リモートの本を 127.0.0.1 の口で中継する相手 1 件。
/// サンドボックスのビューアの ATS は Tailscale（100.64/10）や公開の IP への平文の HTTP を止めるので、
/// ビューアには手元の 127.0.0.1 を渡し、StackNest がリモートのサーバとの間を取り次ぐ。
public struct ViewerRelayTarget: Sendable, Equatable {
    public let serverID: UUID
    /// このクライアントがサーバへ繋いでいる URL（`http://host:port/`）。
    public let serverBase: URL
    public let libraryUUID: String
    public let bookID: Int
    /// リモートのサーバが出した本専用の鍵（平文）。**メモリにだけ置く**。保存・ログ・表示に出さない。
    public let remoteToken: String

    public init(serverID: UUID, serverBase: URL, libraryUUID: String, bookID: Int, remoteToken: String) {
        self.serverID = serverID
        self.serverBase = serverBase
        self.libraryUUID = libraryUUID
        self.bookID = bookID
        self.remoteToken = remoteToken
    }

    /// リモートの本の API の基点（`…/api/v1/libraries/<lib>/books/<id>`）。
    public var remoteBookURL: String {
        BookReference.bookURL(serverBase: serverBase, libraryUUID: libraryUUID, bookID: bookID)
    }
}

/// リモートの鍵を print・dump・失敗メッセージ・ログへ出さない。
extension ViewerRelayTarget: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "ViewerRelayTarget(server: \(serverID), book: \(libraryUUID)/\(bookID), remoteToken: <redacted>)"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["serverID": serverID, "serverBase": serverBase, "libraryUUID": libraryUUID,
                                "bookID": bookID, "remoteToken": "<redacted>"])
    }
}

/// G60 v3（spec §5.8・試用）: 中継の記録（`relayID` → 相手）。**メモリにだけ置く**（リモートの鍵を平文で持つため保存しない）。
/// StackNest を終了すると消え、その後に中継の鍵で来た要求は 401 になる（「StackNest から開き直して」）。
///
/// 記録ごとに期限（中継の鍵とリモートの鍵の早い方）を持ち、引くたびに期限の切れた記録を消す
/// （リモートの鍵が切れた後まで平文を持ち続けない）。期限の切れた中継は「記録が無い」と同じ扱い（401）。
///
/// `@unchecked Sendable`: 可変の `entries` への出入りはすべて `NSLock` で直列化している。
public final class ViewerRelayRegistry: @unchecked Sendable {
    public static let shared = ViewerRelayRegistry()

    private struct Entry {
        let target: ViewerRelayTarget
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    /// 登録して `relayID`（UUID の文字列・URL の 1 階層にそのまま使える）を返す。開くたびに別の中継にする。
    /// - Parameter expiresAt: この中継を使える期限（中継の鍵とリモートの鍵の早い方）。既定は期限なし。
    public func register(_ target: ViewerRelayTarget, expiresAt: Date = .distantFuture,
                         now: Date = Date()) -> String {
        let relayID = UUID().uuidString
        lock.withLock {
            pruneLocked(now: now)
            entries[relayID] = Entry(target: target, expiresAt: expiresAt)
        }
        return relayID
    }

    /// 中継の相手。無い・期限が切れていれば nil（期限の切れた記録はここで消す）。
    public func target(for relayID: String, now: Date = Date()) -> ViewerRelayTarget? {
        lock.withLock {
            pruneLocked(now: now)
            return entries[relayID]?.target
        }
    }

    /// 今ある（期限の切れていない）中継か。起動時の掃除（`ViewerTokenStore.removeRelayTokens`）が使う。
    public func isLive(_ relayID: String, now: Date = Date()) -> Bool {
        target(for: relayID, now: now) != nil
    }

    public var count: Int {
        lock.withLock { entries.count }
    }

    /// `lock` を握った状態で呼ぶこと。
    private func pruneLocked(now: Date) {
        // 数はリモートの本を外部ビューアで開いた回数だけ。切れたものがあるときだけ作り直す。
        guard entries.values.contains(where: { $0.expiresAt <= now }) else { return }
        entries = entries.filter { $0.value.expiresAt > now }
    }
}
