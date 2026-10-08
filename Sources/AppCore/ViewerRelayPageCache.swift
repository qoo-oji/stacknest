// SPDX-License-Identifier: MIT
import Foundation

/// G60 §5.9（2026-10-08 作者の決定）: 内蔵ビューアがリモートのページを頼む形。中継（127.0.0.1 の口）も同じ形で
/// 頼んでキャッシュに入れ、内蔵ビューアとキャッシュを分け合う。値と版の剥がし方は**ここ 1 か所**に置く
/// （内蔵の `RemoteLibraryState`・`RemoteBookContent` と中継の両方が使う。ずれるとキーが食い違い、分け合えない）。
public enum RemoteViewerPage {
    /// 内蔵ビューアがリモートのページを頼む幅（`?maxw=`）。キャッシュのキーの `maxw` にも入る。
    public static let maxWidth = 1600

    /// manifest の `etag`（HTTP の ETag の形で前後に `"` が付く）から、ページの版（`?v=` とキャッシュのキー）を作る。
    /// 前後の `"` を剥がす。両端に `"` が無い・2 文字未満の値はそのまま（サーバの `stripETagQuotes` と同じ規則）。
    public static func version(fromManifestETag raw: String?) -> String? {
        guard let raw, raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        return String(raw.dropFirst().dropLast())
    }
}

/// G60 §5.9: 中継がページのキャッシュを引く・入れるときのキー。内蔵ビューアの `RemotePageCache.Key`
/// （`kind: .page`）と同じ部品で、幅はいつも `RemoteViewerPage.maxWidth`。
public struct ViewerRelayPageKey: Hashable, Sendable {
    public let serverID: UUID
    public let libraryUUID: String
    public let bookID: Int
    public let page: Int
    public let maxw: Int
    /// manifest の `etag` を `RemoteViewerPage.version(fromManifestETag:)` に通した版。etag が無ければ nil。
    public let version: String?

    public init(target: ViewerRelayTarget, page: Int) {
        self.serverID = target.serverID
        self.libraryUUID = target.libraryUUID
        self.bookID = target.bookID
        self.page = page
        self.maxw = RemoteViewerPage.maxWidth
        self.version = RemoteViewerPage.version(fromManifestETag: target.manifestETag)
    }
}

/// G60 §5.9: 中継が使うページのキャッシュ。App は内蔵ビューアと同じキャッシュ（`RemotePageCacheRelayAdapter.shared`）を
/// 渡す。LibraryServer は RemoteClient に依存しないので、ここには口だけを置く。上限・保持期間・消去は渡す側
/// （内蔵ビューアと同じ設定）に従い、中継は足さない。1 冊ごとの上限も設けない（2026-10-08 作者の決定）ので、容量の口は無い。
public protocol ViewerRelayPageCache: Sendable {
    /// あれば返す（取りに行かない）。
    func cachedPage(_ key: ViewerRelayPageKey) async -> Data?
    /// 入れる（入れた後の退避は内蔵ビューアのキャッシュと同じに走る）。
    func storePage(_ data: Data, for key: ViewerRelayPageKey) async
    /// その本・その版で、キャッシュにあるページ番号（先読みが取らずに済ませる分）。
    func cachedPageIndices(for target: ViewerRelayTarget) async -> Set<Int>
}
