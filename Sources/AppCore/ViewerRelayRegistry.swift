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
    /// G60 §5.9: 本のページ数（先読みの範囲）。渡した時点の manifest の値で、ビューアが manifest を読み直したら
    /// 中継がその値に合わせる（`ViewerRelayRegistry.updateBook`）。
    public let pageCount: Int
    /// G60 §5.9: manifest の `etag`（HTTP の形のまま）。ページのキャッシュのキーと `?v=` の版の出どころ
    /// （`ViewerRelayPageKey` が `RemoteViewerPage.version(fromManifestETag:)` に通す）。
    public let manifestETag: String?

    public init(serverID: UUID, serverBase: URL, libraryUUID: String, bookID: Int, remoteToken: String,
                pageCount: Int = 0, manifestETag: String? = nil) {
        self.serverID = serverID
        self.serverBase = serverBase
        self.libraryUUID = libraryUUID
        self.bookID = bookID
        self.remoteToken = remoteToken
        self.pageCount = pageCount
        self.manifestETag = manifestETag
    }

    /// リモートの本の API の基点（`…/api/v1/libraries/<lib>/books/<id>`）。
    public var remoteBookURL: String {
        BookReferences.bookURL(serverBase: serverBase, libraryUUID: libraryUUID, bookID: bookID).absoluteString
    }

    /// ページ数と etag だけを替えたもの（ほか、リモートの鍵もそのまま）。
    func with(pageCount: Int, manifestETag: String?) -> ViewerRelayTarget {
        ViewerRelayTarget(serverID: serverID, serverBase: serverBase, libraryUUID: libraryUUID, bookID: bookID,
                          remoteToken: remoteToken, pageCount: pageCount, manifestETag: manifestETag)
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
                                "bookID": bookID, "pageCount": pageCount, "manifestETag": manifestETag as Any,
                                "remoteToken": "<redacted>"])
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

    /// G60 §5.9: ビューアが読んだ manifest（中継が素通しした応答）のページ数と etag に合わせる。
    /// リモートの鍵と期限はそのまま。変わったら true（無い・期限切れ・同じなら false）。
    @discardableResult
    public func updateBook(_ relayID: String, pageCount: Int, manifestETag: String?, now: Date = Date()) -> Bool {
        lock.withLock {
            pruneLocked(now: now)
            guard let entry = entries[relayID] else { return false }
            guard entry.target.pageCount != pageCount || entry.target.manifestETag != manifestETag else { return false }
            entries[relayID] = Entry(target: entry.target.with(pageCount: pageCount, manifestETag: manifestETag),
                                     expiresAt: entry.expiresAt)
            return true
        }
    }

    /// G60 §5.9（作者の決定 2026-10-10・Codex P1）: 上流に 401・403 で断られた中継を閉じる（記録を消す）。
    /// 以後その中継の要求は記録が無いのと同じ 401（キャッシュにあるページも返さない）。無ければ何もしない。
    public func close(_ relayID: String) {
        lock.withLock { _ = entries.removeValue(forKey: relayID) }
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
