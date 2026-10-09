// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import HTTPTypes
import Hummingbird
import LibraryServerAPI

/// Bearer トークン認証。比較は定数時間（タイミング攻撃対策・spec §4）。
/// R トークン（読み取り）と RW トークン（編集）の双方を受理し、提示トークンに応じて
/// context.role / context.tier を刻む（RW ゲートは下流ハンドラが role/tier を見て判断する・4.2b-3・B1）。
///
/// adminTier=true のとき: R/W いずれのトークンも admin tier（role=write）として扱う（LAN 信頼環境向け）。
/// adminTier=false のとき: R → read tier、W → edit tier。
///
/// セキュリティ注記: `Authorization: Bearer` ヘッダが無い場合に限り `?token=<t>` クエリを
/// fallback として受理する。`<img>`/`<video>` はカスタムヘッダを送れないための妥協で、
/// トークンが URL/サーバログに残る。トークンは LAN 用・再生成可能・既に QR/localStorage に
/// 存在するため許容する（ヘッダ優先・クエリは fallback）。R/RW いずれも同じコードパスで受理する。
/// G60: 本専用の読み取りトークン（`ViewerTokenStore`）も受け付ける。その本の manifest・pages・cover（GET）と
/// progress（POST）だけを通し（`ViewerTokenRoutes`）、ほかはすべて 403。期限切れは 401。
/// 本専用トークンは Authorization ヘッダでだけ受け付ける（クエリの fallback は `<img>` 用の妥協で、ビューアには
/// 要らない。URL に残る面を増やさない）。発行元のグラントが消えた（scope から外れた）ものは 401。
struct BearerAuthMiddleware<Context: RequestContext & RoleHoldingContext>: RouterMiddleware {
    let token: String
    let editToken: String?
    let adminTier: Bool
    /// グラント解決クロージャ（毎リクエスト現在値を返す＝ライブ反映・C-③a）。
    /// nil = 旧来の token/editToken 直接照合パス（テスト/ローカルコントロール adminTier 用）。
    let grantsProvider: (@Sendable () -> [Grant])?
    /// G23 (#9/#10): クエリに載る短命セッショントークンの解決先。
    let sessionTokenStore: SessionTokenStore
    /// G60: 本専用トークンの保存先。nil ならこの口では受け付けない。
    var viewerTokens: ViewerTokenStore? = nil
    /// G60: この口の発行先。
    var viewerTokenIssuer: ViewerTokenIssuer = .sharedServer
    /// G60: false なら grant・R/RW トークンを受け付けない（本専用トークンだけの口）。
    var acceptsPrincipalTokens: Bool = true

    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let presented: String?
        // G60: 本専用トークンはヘッダで出されたときだけ照合する。
        let presentedInHeader: Bool
        if let header = request.headers[.authorization], header.hasPrefix("Bearer ") {
            presented = String(header.dropFirst("Bearer ".count))   // ヘッダ優先
            presentedInHeader = true
        } else if let rawQueryToken = request.uri.queryParameters.get("token") {
            let queryToken = String(rawQueryToken)
            // G23 (#9/#10): クエリに載るのは短命セッショントークン。
            // 解決できなければ、従来どおり grant token 直挿しとして扱う（既存クライアント互換）。
            presented = await sessionTokenStore.resolve(queryToken) ?? queryToken
            presentedInHeader = false
        } else {
            presented = nil
            presentedInHeader = false
        }
        guard let presented else { throw HTTPError(.unauthorized) }
        var ctx = context
        if acceptsPrincipalTokens, let p = principal(for: presented) {
            ctx.role = p.role
            ctx.tier = p.tier
            ctx.scope = p.scope
            // G23 (M3): unlock のレート制限を principal 単位にするための識別子。
            // トークンの生値ではなく grant の id を使う（ログや状態に秘密を残さない）。
            if let grantID = p.grantID { ctx.grantID = grantID }
            return try await next(request, ctx)
        }
        if presentedInHeader, let viewerTokens {
            switch viewerTokens.lookup(token: presented, issuer: viewerTokenIssuer) {
            case .valid(let record):
                // 共有サーバで発行したトークンは、発行元のグラントが今もあり、その書庫を scope に含むときだけ
                // 有効（グラントの削除・scope の縮小で即時に失効させる。/events の再検証と同じ考え方）。
                // 失効したトークンは「無効なトークン」なので、道の検査より先に 401 にする。
                if let grantID = record.issuedByGrantID {
                    guard let grantsProvider,
                          let grant = grantsProvider().first(where: { $0.id == grantID }),
                          grant.scope.allows(record.libraryUUID) else {
                        throw HTTPError(.unauthorized)
                    }
                }
                // 道の検査はルートの解決結果ではなく実際のパスで行う（その本の 4 つの道だけ）。
                // G60 v3（spec §5.8）: 中継の鍵は、その relayID の中継の 4 つの道だけ（本の道は通さない）。
                let allowed: Bool
                if let relayID = record.relayID {
                    allowed = ViewerTokenRoutes.allowsRelay(method: request.method, path: request.uri.path,
                                                            relayID: relayID)
                } else {
                    allowed = ViewerTokenRoutes.allows(method: request.method, path: request.uri.path,
                                                       libraryUUID: record.libraryUUID, bookID: record.bookID)
                }
                guard allowed else { throw HTTPError(.forbidden) }
                ctx.role = .read
                ctx.tier = .read
                // 中継の鍵は手元のどの書庫も読めない（scope は空）。
                ctx.scope = .libraries(record.relayID == nil ? [record.libraryUUID] : [])
                ctx.grantID = "viewer-token:\(record.id)"
                ctx.viewerBook = ViewerBookAccess(libraryUUID: record.libraryUUID, bookID: record.bookID,
                                                  lockFingerprint: record.lockFingerprint, relayID: record.relayID,
                                                  bookStamp: record.bookStamp)
                // G60 v3: 初めて通ったときに一度だけ、使われた日時と名乗りを記録する（spec §5.7）。
                // ここに来るのは照合・発行元グラント・道の検査を通った要求だけ。この中間処理が返す 401・403 は数えない（下流の施錠の 403 は数える）。
                // 以後は照合の結果を見るだけで書かない（ページを取るたびに保存しない）。
                // 中継の鍵（spec §5.8）では、記録は中継の記録の照合（401）と取り次ぎ（502）より前に書く。
                // これは意図した動き（`ViewerRelayTests.relayFirstUseMeansReachingTheEndpoint` で固定）。
                // つまり中継の鍵の「初回使用」は「ビューアが有効な中継の鍵で 127.0.0.1 の口に届いた」ことで、
                // 「本を読み込んだ」ことではない（リモートが落ちていて 502 でも、終了後の孤児の鍵で 401 でも記録される）。
                if record.firstUsedAt == nil {
                    viewerTokens.recordFirstUse(
                        id: record.id, viewer: request.headers[ViewerTokenRoutes.identificationHeader])
                }
                return try await next(request, ctx)
            case .expired:
                throw HTTPError(.unauthorized)
            case .unknown:
                break
            }
        }
        throw HTTPError(.unauthorized)
    }

    private struct Principal {
        let role: TokenRole
        let tier: AccessTier
        let scope: GrantScope
        /// grant の id。固定トークン経路は nil（コンテキストの既定 "legacy" のまま）。
        let grantID: String?
    }

    /// grant／R・RW トークンとして照合する（従来の判定そのまま）。一致しなければ nil。
    private func principal(for presented: String) -> Principal? {
        if let grantsProvider {
            // グラントモード（ライブ）: 毎リクエスト現在のグラントを取得し照合、tier/scope を刻む。
            // 削除済みグラント＝マッチなし＝401＝即時失効。
            guard let g = grantsProvider().first(where: { constantTimeEquals(presented, $0.token) }) else {
                return nil
            }
            return Principal(role: (g.tier == .read) ? .read : .write, tier: g.tier, scope: g.scope, grantID: g.id)
        }
        if adminTier {
            // adminTier モード: R/W いずれかのトークンが一致すれば admin 昇格。
            if constantTimeEquals(presented, token) || (editToken.map { constantTimeEquals(presented, $0) } ?? false) {
                return Principal(role: .write, tier: .admin, scope: .all, grantID: nil)
            }
            return nil
        }
        if constantTimeEquals(presented, token) {
            return Principal(role: .read, tier: .read, scope: .all, grantID: nil)
        }
        if let editToken, constantTimeEquals(presented, editToken) {
            return Principal(role: .write, tier: .edit, scope: .all, grantID: nil)
        }
        return nil
    }
}

/// G60: 本専用トークンで認証された主体が読める 1 冊。
public struct ViewerBookAccess: Sendable, Equatable {
    public let libraryUUID: String
    public let bookID: Int
    /// 発行時に解錠していたロックの世代（`ViewerTokenStore.lockFingerprint(for:)`）。未施錠で発行したら nil。
    public let lockFingerprint: String?

    /// G60 v3（spec §5.8）: 中継の鍵なら、その中継の id（中継のルートが照らす）。本の鍵は nil。
    public let relayID: String?

    /// G60（Codex P1・2 回目）: 発行したときの本の印（`ViewerTokenRecord.bookStamp`）。本の道は今の本の印と照らす。
    public let bookStamp: String?

    public init(libraryUUID: String, bookID: Int, lockFingerprint: String?, relayID: String? = nil,
                bookStamp: String? = nil) {
        self.libraryUUID = libraryUUID
        self.bookID = bookID
        self.lockFingerprint = lockFingerprint
        self.bookStamp = bookStamp
        self.relayID = relayID
    }
}

/// G60: 本専用トークンが通れる道。その本の manifest・pages/{n}・cover（GET）と progress（POST）だけ。
/// 末尾のスラッシュ・大文字違い・余計な階層は通さない（安全側に倒す）。
enum ViewerTokenRoutes {
    /// G60 v3: 対応ビューアの名乗り（`X-StackNest-Viewer`）。値は `ViewerTokenStore.recordFirstUse` が整える。
    static let identificationHeader = HTTPField.Name(ViewerIdentification.headerName)!

    static func allows(method: HTTPRequest.Method, path: String, libraryUUID: String, bookID: Int) -> Bool {
        allowsBookRequest(method: method, path: path, prefix: "/api/v1/libraries/\(libraryUUID)/books/\(bookID)/")
    }

    /// G60 v3（spec §5.8）: 中継の鍵が通れる道。その relayID の manifest・pages/{n}・cover（GET）と progress（POST）だけ。
    static func allowsRelay(method: HTTPRequest.Method, path: String, relayID: String) -> Bool {
        allowsBookRequest(method: method, path: path, prefix: "/api/v1/relay/\(relayID)/")
    }

    /// `prefix` の後ろが本の 4 つの道のどれかか。
    private static func allowsBookRequest(method: HTTPRequest.Method, path: String, prefix: String) -> Bool {
        guard path.hasPrefix(prefix) else { return false }
        let rest = path.dropFirst(prefix.count)
        switch method {
        case .get:
            if rest == "manifest" || rest == "cover" { return true }
            guard rest.hasPrefix("pages/") else { return false }
            let n = rest.dropFirst("pages/".count)
            return !n.isEmpty && n.allSatisfy { $0.isASCII && $0.isNumber }
        case .post:
            return rest == "progress"
        default:
            return false
        }
    }
}

/// 長さが異なっても全バイト走査する定数時間比較。
/// BearerAuthMiddleware と /events の長寿命接続再検証（liveConnectionStillAuthorized）の双方から
/// 共有するためファイルスコープ関数として公開する（タイミング攻撃対策・spec §4）。
func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let aBytes = Array(a.utf8), bBytes = Array(b.utf8)
    var diff = aBytes.count ^ bBytes.count
    for i in 0..<max(aBytes.count, bBytes.count) {
        let x = i < aBytes.count ? aBytes[i] : 0
        let y = i < bBytes.count ? bBytes[i] : 0
        diff |= Int(x ^ y)
    }
    return diff == 0
}

/// SSE 長寿命接続の再認証: 接続時に認証された grant が現存し、その scope が接続時 scope と一致するか。
/// grants に該当 id が無い＝失効、scope が変わった＝再接続で更新すべき → いずれも false。
///
/// G23 (#9/#10) Codex High #1: 以前は**提示トークン文字列**を grant token と突き合わせていたが、
/// クエリに載るのが短命セッショントークンになったため、その比較は必ず失敗していた
/// （= ハートビート毎に SSE が切断される）。ミドルウェアが解決済みの grant id で判定する。
/// id は秘密ではないため、長寿命 Task が秘密を保持しなくて済む。
/// 固定トークン経路（grantsProvider 不在）ではそもそも本関数を呼ばない。
func liveConnectionStillAuthorized(grantID: String, subscribedScope: GrantScope, grants: [Grant]) -> Bool {
    guard let g = grants.first(where: { $0.id == grantID }) else { return false }
    return g.scope == subscribedScope
}
