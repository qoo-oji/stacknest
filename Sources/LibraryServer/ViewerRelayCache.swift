// SPDX-License-Identifier: MIT
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import AppCore
import LibraryServerAPI

/// G60 §5.9: キャッシュの道で 1 ページを取った結果。
enum SharedPageOutcome: Sendable {
    /// キャッシュにあった（リモートへ行っていない）。
    case hit(Data)
    /// リモートから 200 で取った。`stored` は入れたか（`Cache-Control: no-store` なら false）。
    case fetched(Data, stored: Bool)
    /// リモートが 200・3xx 以外を返した（状態コード・許可リストのヘッダ・本文をそのまま返す）。
    case upstream(status: Int, headers: HTTPFields, body: Data)
    /// 届かない・時間切れ・大きすぎる・リダイレクト。
    case failed
}

/// G60 §5.9: 同じページを同時に頼まれたら（ビューアと先読み、ビューアの 2 本）、リモートへは 1 回だけ取りに行く。
/// 取りに行く作業は頼んだ側の取り消しから切り離す（先読みを止めても、取り中の分は最後まで取ってキャッシュに入れる）。
actor ViewerRelayPageLoader {
    private var inFlight: [ViewerRelayPageKey: Task<SharedPageOutcome, Never>] = [:]
    private var joined: [ViewerRelayPageKey: Int] = [:]

    func load(_ key: ViewerRelayPageKey,
              _ work: @escaping @Sendable () async -> SharedPageOutcome) async -> SharedPageOutcome {
        if let running = inFlight[key] {
            joined[key, default: 0] += 1
            return await running.value
        }
        let task = Task { await work() }
        inFlight[key] = task
        let outcome = await task.value
        inFlight[key] = nil
        joined[key] = nil
        return outcome
    }

    /// テスト用: 取り中のページの数。
    var inFlightCount: Int { inFlight.count }

    /// テスト用: 取り中の作業に相乗りした要求の数。
    func joinedCount(for key: ViewerRelayPageKey) -> Int { joined[key] ?? 0 }
}

extension ViewerRelayForwarder {
    /// キャッシュの道を使う要求か: `maxw` が無い（数でない・0 以下も無いとみなす＝素通しのときと同じ扱い）か、内蔵の幅と同じ。
    static func usesSharedVariant(_ request: Request) -> Bool {
        guard let maxw = request.uri.queryParameters.get("maxw", as: Int.self), maxw > 0 else { return true }
        return maxw == RemoteViewerPage.maxWidth
    }

    /// 中継の `pages/{n}`。認証は `handle` と同じ（`authorize`）で、キャッシュはその後でだけ引く。
    /// キャッシュを使う形で、`maxw` が無い（または内蔵の幅の）要求は、内蔵ビューアと分け合うキャッシュから返す。
    /// ほかは今までどおり取り次ぐ。
    static func handlePage(_ request: Request, _ context: some RequestContext & RoleHoldingContext, page: Int,
                           relay: ViewerRelayConfig) async throws -> Response {
        let (relayID, target) = try authorize(context, relay: relay)
        guard let cache = relay.pageCache, usesSharedVariant(request) else {
            return await forward(target, remotePath: "pages/\(page)", request: request, body: nil, relay: relay)
        }
        let viewer = ViewerIdentification.sanitize(request.headers[ViewerTokenRoutes.identificationHeader])
        // ビューアの要求のあいだ、先読みは新しく取りに行かず、中心をこのページへ移す（先読みが終わっていれば、
        // このページのまわりで始め直す）。間に投げる処理は置かない（`loadSharedPage` は投げない）ので、終わりの知らせは必ず届く。
        await relay.prefetcher?.liveRequestBegan(relayID: relayID, page: page)
        let outcome = await loadSharedPage(target, page: page, viewer: viewer, cache: cache, loader: relay.loader,
                                           session: relay.session, limit: relay.maxResponseBytes)
        await relay.prefetcher?.liveRequestEnded(relayID: relayID)
        return sharedPageResponse(outcome)
    }

    /// キャッシュにあれば返す。無ければ内蔵ビューアと同じ形（`maxw`＝内蔵の幅・`v`＝版）でリモートから取り、
    /// `Cache-Control: no-store` でなければ入れる（`RemoteBookContent.imageData` と同じ）。同時の同じページは 1 回だけ取る。
    /// - Parameter viewer: 整えた名乗り（ビューアの要求のとき）。先読みは nil。
    static func loadSharedPage(_ target: ViewerRelayTarget, page: Int, viewer: String?,
                               cache: any ViewerRelayPageCache, loader: ViewerRelayPageLoader,
                               session: URLSession, limit: Int) async -> SharedPageOutcome {
        let key = ViewerRelayPageKey(target: target, page: page)
        if let hit = await cache.cachedPage(key) { return .hit(hit) }
        return await loader.load(key) {
            // 待っている間に、ほかの要求が取り終えて入れているかもしれない。
            if let hit = await cache.cachedPage(key) { return .hit(hit) }
            guard let request = Self.makeSharedPageRequest(target, key: key, viewer: viewer) else { return .failed }
            switch await Self.load(request, session: session, limit: limit) {
            case .tooLarge, .failed:
                return .failed
            case .response(let http, let data):
                // リダイレクトは辿らない（If-None-Match を送らないので 304 は来ない）。
                if (300...399).contains(http.statusCode) { return .failed }
                guard http.statusCode == 200 else {
                    return .upstream(status: http.statusCode, headers: Self.copiedHeaders(http), body: data)
                }
                let noStore = (http.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased().contains("no-store")
                if !noStore { await cache.storePage(data, for: key) }
                return .fetched(data, stored: !noStore)
            }
        }
    }

    /// 内蔵ビューアと同じ形の要求（`pages/{n}?maxw=<内蔵の幅>&v=<版>`・リモートの鍵）。`If-None-Match` は付けない。
    static func makeSharedPageRequest(_ target: ViewerRelayTarget, key: ViewerRelayPageKey,
                                      viewer: String?) -> URLRequest? {
        guard var components = URLComponents(string: target.remoteBookURL + "/pages/\(key.page)") else { return nil }
        var items = [URLQueryItem(name: "maxw", value: String(key.maxw))]
        if let version = key.version { items.append(URLQueryItem(name: "v", value: version)) }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var outgoing = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        outgoing.httpMethod = "GET"
        outgoing.httpShouldHandleCookies = false
        outgoing.setValue("Bearer \(target.remoteToken)", forHTTPHeaderField: "Authorization")
        if let viewer { outgoing.setValue(viewer, forHTTPHeaderField: ViewerIdentification.headerName) }
        return outgoing
    }

    /// キャッシュの道の応答。取れたら画像と `Content-Type` だけ（`ETag` は付けない）。
    static func sharedPageResponse(_ outcome: SharedPageOutcome) -> Response {
        switch outcome {
        case .hit(let data), .fetched(let data, _):
            var headers = HTTPFields()
            headers[.contentType] = sniffImageContentType(data)
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
        case .upstream(let status, let headers, let body):
            return Response(status: HTTPResponse.Status(code: status), headers: headers,
                            body: .init(byteBuffer: ByteBuffer(bytes: body)))
        case .failed:
            return Response(status: .badGateway)
        }
    }

    /// G60 §5.9: 素通しした manifest（200）に、中継の記録のページ数と版を合わせる。内蔵ビューアが
    /// 「開いた時点の manifest」の版でページを引くのと同じで、ビューアに見せたページ数と、引く版を同じ manifest から取る。
    /// 変わったら、最後に渡した本なら先読みし直す。読めない本文なら何もしない。
    static func noteManifest(_ data: Data, relayID: String, relay: ViewerRelayConfig) async {
        guard let manifest = try? JSONDecoder().decode(ManifestDTO.self, from: data) else { return }
        if relay.registry.updateBook(relayID, pageCount: manifest.pageCount, manifestETag: manifest.etag) {
            await relay.prefetcher?.versionChanged(relayID: relayID)
        }
    }

    /// G60 §5.9: 先読み係を組む。取るのは中継自身の道（リモートの鍵・内蔵の幅と版・名乗りなし）で、
    /// ビューアの要求と同じ `loader` を通す（同じページは 1 回だけ取る）。1 枚ごとに中継の記録を引き直す
    /// （終了・期限切れ・版の更新をここで拾う）。範囲の設定は `wholeBook` を先読み係がそのまま読む。
    static func makePrefetcher(registry: ViewerRelayRegistry, session: URLSession, limit: Int,
                               cache: any ViewerRelayPageCache, loader: ViewerRelayPageLoader,
                               tuning: ViewerRelayPrefetcher.Tuning,
                               wholeBook: @escaping @Sendable () -> Bool) -> ViewerRelayPrefetcher {
        ViewerRelayPrefetcher(
            tuning: tuning,
            plan: { relayID in
                guard let target = registry.target(for: relayID) else { return nil }
                return (pageCount: target.pageCount, cached: await cache.cachedPageIndices(for: target))
            },
            fetch: { relayID, page in
                guard let target = registry.target(for: relayID) else { return .relayGone }
                let outcome = await Self.loadSharedPage(target, page: page, viewer: nil, cache: cache, loader: loader,
                                                        session: session, limit: limit)
                return Self.prefetchOutcome(outcome)
            },
            wholeBook: wholeBook)
    }

    /// キャッシュの道の結果 → 先読みの結果。
    static func prefetchOutcome(_ outcome: SharedPageOutcome) -> ViewerRelayPrefetcher.Outcome {
        switch outcome {
        case .hit:
            return .alreadyCached
        case .fetched(_, let stored):
            return stored ? .fetched : .stale
        case .upstream(let status, _, _):
            // 401（リモートの鍵の期限・取り消し）・403（施錠・範囲の外）・404（本が消えた・ページの範囲の外）・410 は
            // 取り直しても同じ。ほか（5xx・429 など）は間をあけて取り直す。
            return [401, 403, 404, 410].contains(status) ? .refused : .failed
        case .failed:
            return .failed
        }
    }
}
