// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore
import AppCore

/// 本ごとの BookContent ハンドルを TTL 付きで保持（アーカイブ再オープン排除・spec §3.3）。
/// key は (libraryUUID, bookID)。アクセスごとに鮮度を更新し、期限切れは次回アクセス時に掃除。
public actor BookContentCache {
    /// row の content 基準（path/mtime/size）。bookETag（ContentEndpoints.swift）と同じ
    /// 3 信号源を使い、relink 後の再構築判定と ETag の変化が食い違わないようにする（G4d 層0）。
    /// mtime/size は effectiveFileStat 経由（＝フォルダブックは nil のとき request 時 stat で埋める）。
    /// これを bookETag と共有しないと、ETag だけが動いてサーバ自身が持つ FolderBookContent の
    /// キャッシュは古いままという食い違いが起きる（最終レビュー Finding 1）。
    private struct Basis: Equatable {
        let path: String?
        let mtime: Double?
        let size: Int64?
        /// G64 Codex fix: content を作ったときの足した拡張子の一覧。変われば作り直す
        /// （.tgz を登録する前に作った圧縮 tar 不可の content を、登録後も返し続けない）。
        let userExtensions: UserExtensionMap
    }

    private struct Entry {
        let content: any BookContent
        var lastAccess: ContinuousClock.Instant
        let basis: Basis
    }

    private var entries: [String: Entry] = [:]
    private let ttl: Duration
    private let clock = ContinuousClock()
    /// G64: 本を作るときの足した拡張子の一覧（書庫を持つ Mac の一覧。`LibraryServerConfig.userExtensions`）。
    private let userExtensions: @Sendable () -> UserExtensionMap

    public init(ttlSeconds: Int,
                userExtensions: @escaping @Sendable () -> UserExtensionMap = { UserExtensionStore.shared.snapshot }) {
        self.ttl = .seconds(ttlSeconds)
        self.userExtensions = userExtensions
    }

    public func content(for row: BookRow, libraryUUID: String) throws -> any BookContent {
        try contentAndETag(for: row, libraryUUID: libraryUUID).content
    }

    /// content と、それと**同じ 1 回の effectiveFileStat 呼び出し**から作った ETag 文字列を
    /// 一緒に返す（Finding 2）。
    ///
    /// 修正前は manifest/pages ハンドラが `contentCache.content(for:libraryUUID:)`（内部で
    /// effectiveFileStat を呼ぶ）と、その**後で別に** `bookETag(for: row)`（内部でもう一度
    /// independently に effectiveFileStat を呼ぶ）の 2 回、ディレクトリを stat していた。
    /// フォルダ本は request 時に毎回ディレクトリを stat する（effectiveFileStat のコメント参照）
    /// ため、この 2 回の stat の間にディレクトリが変化すると、advertise した ETag が実際に
    /// 返したページ数/バイトと対応しなくなる。
    /// ここで mtime/size を 1 回だけ取得し、content 用の Basis と ETag 文字列の両方をそこから
    /// 組み立てることで、呼び出し側（manifest/pages ハンドラ）は二度と `bookETag(for: row)` を
    /// 呼び直す必要がなくなる＝食い違いの余地自体を無くす。
    /// ETag のフォーマットは `bookETag(for:)`（ContentEndpoints.swift）と**バイト完全一致**——
    /// 同じ (row.id, mtime, size, pathHash) から同じ文字列規則で組み立てるため、変化していない
    /// 本では常に同じ値になる（全クライアントの immutable キャッシュを壊さない）。
    ///
    /// G64: content の再利用判定（Basis）には path/mtime/size に加えて**足した拡張子の一覧**も入る。
    /// 一覧が変われば（登録・解除・種類の付け替え）作り直す。ETag には一覧を入れない（本のバイトは
    /// 変わらないので、変化していない本の ETag は一覧の変更をまたいで同じ値のまま）。
    /// 返す `userExtensions` は content を作った（または再利用を許した）のと同じ 1 回のスナップショットで、
    /// 呼び出し側（manifest の format 分類）はこれを使う。
    public func contentAndETag(
        for row: BookRow, libraryUUID: String
    ) throws -> (content: any BookContent, etag: String, userExtensions: UserExtensionMap) {
        let key = "\(libraryUUID)/\(row.id)"
        let now = clock.now
        // 期限切れエントリの掃除（呼び出しごとの軽量 sweep）
        entries = entries.filter { now - $0.value.lastAccess < ttl }
        let (mtime, size) = effectiveFileStat(for: row)
        // 1 リクエスト 1 スナップショット: content の構築・cache 判定・呼び出し側の分類
        // （manifest の format）が同じ一覧を使う。
        let extensions = userExtensions()
        let basis = Basis(path: row.path, mtime: mtime, size: size, userExtensions: extensions)
        let etag = Self.etagString(rowID: row.id, path: row.path, mtime: mtime, size: size)
        if var entry = entries[key], entry.basis == basis {
            entry.lastAccess = now
            entries[key] = entry
            return (entry.content, etag, extensions)
        }
        // 未キャッシュ、または content 基準（path/mtime/size・足した拡張子の一覧）が変化した＝再構築。
        // 旧 Entry の強参照はここで落ち、ArchiveBookContent→SequentialArchiveExtractor の deinit が
        // 走って temp が即掃除される（リモート temp TTL follow-up を相乗りでカバー）。
        let content = try BookContentFactory.make(for: row, userExtensions: extensions)
        entries[key] = Entry(content: content, lastAccess: now, basis: basis)
        return (content, etag, extensions)
    }

    /// `bookETag(for:)`（ContentEndpoints.swift）と同一の文字列規則。effectiveFileStat の
    /// 結果を呼び出し側から受け取る点だけが違う（Finding 2 の「1 回の stat から両方作る」ため）。
    private static func etagString(rowID: Int, path: String?, mtime: Double?, size: Int64?) -> String {
        let m = mtime ?? 0
        let s = size ?? 0
        let pathHash = String(fnv1aHash(path ?? ""), radix: 36)
        return "\"\(rowID)-\(Int(m))-\(s)-\(pathHash)\""
    }
}
