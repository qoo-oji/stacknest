// SPDX-License-Identifier: MIT
import Foundation
import AppCore

/// G60 §5.9（2026-10-08 作者の決定）: 中継（127.0.0.1 の口）に、内蔵ビューアと同じリモートのページの
/// キャッシュ（`RemotePageCache`）を渡す。LibraryServer は RemoteClient に依存しないので、AppCore の口
/// （`ViewerRelayPageCache`）に合わせてここで橋渡しする。
///
/// キーは内蔵ビューア（`RemoteBookContent.imageData`）と同じ部品で組む: `kind: .page`・幅は
/// `RemoteViewerPage.maxWidth`・版は `RemoteViewerPage.version(fromManifestETag:)`（どちらも `ViewerRelayPageKey` が持つ）。
/// 本物のキャッシュは使うときに引く（`LocalControlController()` を作るだけのテストで `~/Library` に置き場を作らない）。
public struct RemotePageCacheRelayAdapter: ViewerRelayPageCache {
    /// アプリが中継に渡すもの（内蔵ビューアと同じ `RemotePageCache.shared`）。
    public static let shared = RemotePageCacheRelayAdapter { RemotePageCache.shared }

    private let cache: @Sendable () -> RemotePageCache

    public init(cache: @escaping @Sendable () -> RemotePageCache) {
        self.cache = cache
    }

    /// 中継のキー → 内蔵ビューアのキー。
    static func cacheKey(_ key: ViewerRelayPageKey) -> RemotePageCache.Key {
        RemotePageCache.Key(serverID: key.serverID, libraryUUID: key.libraryUUID, bookID: key.bookID,
                            kind: .page, page: key.page, maxw: key.maxw, version: key.version)
    }

    public func cachedPage(_ key: ViewerRelayPageKey) async -> Data? {
        await cache().cachedData(for: Self.cacheKey(key))
    }

    public func storePage(_ data: Data, for key: ViewerRelayPageKey) async {
        await cache().insert(data, for: Self.cacheKey(key))
    }

    public func cachedPageIndices(for target: ViewerRelayTarget) async -> Set<Int> {
        let probe = ViewerRelayPageKey(target: target, page: 0)
        return await cache().cachedPages(serverID: probe.serverID, libraryUUID: probe.libraryUUID,
                                         bookID: probe.bookID, maxw: probe.maxw, version: probe.version)
    }
}
