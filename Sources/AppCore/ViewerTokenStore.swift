// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit

/// G60: 本専用の読み取りトークンを、どの口が発行したか。
/// 発行した口とは別の口では使えない（共有サーバで出したトークンは 127.0.0.1 の口で通らず、逆も同じ）。
public enum ViewerTokenIssuer: String, Codable, Sendable, CaseIterable {
    /// ネットワーク共有のサーバ（`ServerController`）。
    case sharedServer
    /// この Mac の中だけの口（127.0.0.1・`LocalControlController`）。
    case localEndpoint
}

/// G60: 発行した本専用トークン 1 件の記録。**トークンの平文は持たない**（`tokenHash` だけ）。
public struct ViewerTokenRecord: Codable, Sendable, Equatable {
    public let id: String
    /// トークンの SHA-256（16 進）。
    public let tokenHash: String
    public let libraryUUID: String
    public let bookID: Int
    public let issuer: ViewerTokenIssuer
    public let issuedAt: Date
    public let expiresAt: Date
    /// 発行したときに解錠していたロックの世代（`ViewerTokenStore.lockFingerprint(for:)`）。
    /// 施錠していない書庫で発行したら nil。施錠庫では、これが今の世代と一致するときだけその本を通す
    /// （パスワードを変えたら、それ以前に出したトークンでは読めなくなる・G25d の書庫トークンと同じ考え方）。
    public let lockFingerprint: String?
    /// 発行した接続のグラントの id（共有サーバの `POST …/viewer-token`）。認証のたびにこのグラントが
    /// 今もあり、その書庫を scope に含むことを確かめる（グラントの削除・scope の縮小で即時に失効）。
    /// アプリが手元で出したもの（127.0.0.1 の口用）と固定トークンで出したものは nil（グラントに結び付かない）。
    public let issuedByGrantID: String?
}

/// G60: 発行の結果。平文の `token` は呼び出し元へ 1 度だけ渡し、保存しない。
public struct IssuedViewerToken: Sendable, Equatable {
    public let token: String
    public let record: ViewerTokenRecord
}

/// G60: 提示されたトークンの照合結果。
public enum ViewerTokenLookup: Sendable, Equatable {
    case valid(ViewerTokenRecord)
    /// 期限が切れている（サーバは 401 を返す＝ビューアは「StackNest から開き直して」を出す）。
    case expired
    /// 知らない、または別の口で発行したトークン。
    case unknown
}

/// G60: 本専用の読み取りトークンの保存先（spec §5.1）。
///
/// - 保存はハッシュだけ。UserDefaults のキー `viewer_tokens` に JSON で置き、再起動後も有効。
/// - 有効期限は 30 日。同じ本を開き直すたびに新しいトークンを出す（古いものは期限まで有効）。
/// - 期限切れは、発行のたびと起動時（`pruneExpired`）に掃除する。
///
/// 共有サーバ・127.0.0.1 の口・アプリの直接発行が**同じインスタンス（`shared`）**を使う。
/// 照合はページを 1 枚取るたびに走るので、記録はメモリに持ち、書き込みのときだけ UserDefaults へ書き出す。
///
/// `@unchecked Sendable`: 可変の `records` への出入りはすべて `NSLock` で直列化している
/// （`InMemoryGrantRepository` と同じ形）。`UserDefaults` はスレッドセーフ。
public final class ViewerTokenStore: @unchecked Sendable {
    public static let defaultsKey = "viewer_tokens"
    /// 有効期限（30 日）。
    public static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    public static let shared = ViewerTokenStore()

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var records: [ViewerTokenRecord]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([ViewerTokenRecord].self, from: data) {
            records = decoded
        } else {
            records = []
        }
    }

    /// トークンの SHA-256（16 進・小文字）。
    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// ロックの世代（書庫に保存されたロックのハッシュ）を、さらにハッシュしたもの。nil なら nil。
    /// ロックのハッシュそのものを UserDefaults へ写さないために、接頭辞を付けて SHA-256 を取る。
    public static func lockFingerprint(for credential: String?) -> String? {
        guard let credential else { return nil }
        return hash("stacknest-lock:" + credential)
    }

    /// 新しいトークンを出す。期限切れの記録はここでも掃除する。
    /// - Parameter issuedByGrantID: 発行した接続のグラントの id。グラントに結び付けないなら nil。
    public func issue(libraryUUID: String, bookID: Int, issuer: ViewerTokenIssuer,
                      lockCredential: String?, issuedByGrantID: String? = nil,
                      now: Date = Date()) -> IssuedViewerToken {
        let token = ServerPreferences.generateToken()
        let record = ViewerTokenRecord(
            id: UUID().uuidString,
            tokenHash: Self.hash(token),
            libraryUUID: libraryUUID,
            bookID: bookID,
            issuer: issuer,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(Self.lifetime),
            lockFingerprint: Self.lockFingerprint(for: lockCredential),
            issuedByGrantID: issuedByGrantID)
        lock.withLock {
            records.removeAll { $0.expiresAt <= now }
            records.append(record)
            persistLocked()
        }
        return IssuedViewerToken(token: token, record: record)
    }

    /// 提示されたトークンを照合する。記録は変えない（掃除は `issue`／`pruneExpired`）。
    /// 比較はハッシュ同士で行う。ハッシュの比較時間から分かるのはハッシュの先頭だけで、
    /// トークンそのものは推測できない。
    public func lookup(token: String, issuer: ViewerTokenIssuer, now: Date = Date()) -> ViewerTokenLookup {
        let presented = Self.hash(token)
        return lock.withLock {
            guard let r = records.first(where: { $0.tokenHash == presented && $0.issuer == issuer }) else {
                return .unknown
            }
            return r.expiresAt > now ? .valid(r) : .expired
        }
    }

    /// 期限切れの記録を消す。消した件数を返す。起動時に呼ぶ。
    @discardableResult
    public func pruneExpired(now: Date = Date()) -> Int {
        lock.withLock {
            let before = records.count
            records.removeAll { $0.expiresAt <= now }
            let removed = before - records.count
            if removed > 0 { persistLocked() }
            return removed
        }
    }

    public func allRecords() -> [ViewerTokenRecord] {
        lock.withLock { records }
    }

    /// `lock` を握った状態で呼ぶこと。
    private func persistLocked() {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
