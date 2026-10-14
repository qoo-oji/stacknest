// SPDX-License-Identifier: MIT
import Foundation
import Synchronization

/// G64: 利用者が足した拡張子 → 種類。鍵は正規化した拡張子（小文字・先頭の `.` なし）、値は
/// アーカイブ・画像・動画・テキストのどれか（`UserExtensionValidator.assignableCategories`）。
/// 標準の拡張子（`BookCategory.presetCategories`）とは重ならない。
public typealias UserExtensionMap = [String: BookCategory]

/// G64: 拡張子を足せない理由。文言は持たない（App が写す。サーバと CLI は使わない）。
/// 拡張子を持つ case の値は正規化した拡張子。
public enum UserExtensionError: Error, Equatable, Sendable {
    /// 正規化した後に空。
    case empty
    /// 形が合わない（`[a-z0-9][a-z0-9_-]{0,15}` でない）。
    case invalidFormat
    /// 標準の拡張子。
    case standard(String)
    /// StackNest が使う拡張子（ライブラリ・参照ファイル・監視フォルダが飛ばす一時ファイル）。
    case reserved(String)
    /// もう足してある。
    case alreadyAdded(String)
    /// 上限（`UserExtensionValidator.maxCount`）に達している。
    case limitReached
}

/// G64: 足す拡張子の正規化と検証（純関数）。
public enum UserExtensionValidator {
    /// 拡張子の長さの上限（作者の決定 2026-10-08）。
    public static let maxLength = 16
    /// 足せる数の上限（作者の決定 2026-10-08）。
    public static let maxCount = 100
    /// 足した拡張子の振り分け先（作者の決定 2026-10-08。フォルダと電子書籍は外す）。並びは画面の Picker の順。
    public static let assignableCategories: [BookCategory] = [.archive, .image, .video, .text]
    /// StackNest が使う拡張子。`part`・`crdownload`・`download`・`tmp` は監視フォルダが一時ファイルとして必ず飛ばすので、
    /// 足すとドロップだけ通って監視フォルダでは取り込まれない不揃いになる。
    public static let reserved: Set<String> = ["stacknest", "stacknestbook", "part", "crdownload", "download", "tmp"]

    /// 入力を保存する形にする: 前後の空白を除き、先頭の `*` を 1 つ、続けて先頭の `.` を 1 つ除き、小文字にする。
    public static func normalize(_ raw: String) -> String {
        var s = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.hasPrefix("*") { s = s.dropFirst() }
        if s.hasPrefix(".") { s = s.dropFirst() }
        return s.lowercased()
    }

    /// 正規化した拡張子の形: 半角の英小文字・数字・`_`・`-` の 1〜16 文字で、先頭は英数字。
    public static func isWellFormed(_ ext: String) -> Bool {
        let scalars = Array(ext.unicodeScalars)
        guard (1...maxLength).contains(scalars.count), isLowerAlnum(scalars[0]) else { return false }
        return scalars.allSatisfy { isLowerAlnum($0) || $0 == "_" || $0 == "-" }
    }

    private static func isLowerAlnum(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("0"..."9").contains(s)
    }

    /// 足してよいかを決める。通れば正規化した拡張子を返す。
    public static func validate(_ raw: String, existing: UserExtensionMap) -> Result<String, UserExtensionError> {
        let ext = normalize(raw)
        if ext.isEmpty { return .failure(.empty) }
        guard isWellFormed(ext) else { return .failure(.invalidFormat) }
        if BookCategory.presetCategories[ext] != nil { return .failure(.standard(ext)) }
        if reserved.contains(ext) { return .failure(.reserved(ext)) }
        if existing[ext] != nil { return .failure(.alreadyAdded(ext)) }
        if existing.count >= maxCount { return .failure(.limitReached) }
        return .success(ext)
    }
}

/// G64: 足した拡張子の一覧の保存と、プロセスで共有するスナップショット。
///
/// 保存は UserDefaults のキー `userBookExtensions`（plist の辞書 `[String: String]`＝拡張子 → 種類の rawValue）。
/// `ViewerSettings` には持たせない: 分類はサーバのハンドラ・`Task.detached`・走査など MainActor の外から呼ばれ、
/// テストは suite ごとに `UserExtensionStore(defaults:)` を作る（`shared` を書き換えない）。
/// `@unchecked Sendable`: 変わる状態は `Mutex` の中だけ。`UserDefaults` はスレッドセーフだが SDK が Sendable を
/// 宣言していないため（`ConfirmedViewerStore` と同じ事情）。
public final class UserExtensionStore: @unchecked Sendable {
    public static let defaultsKey = "userBookExtensions"
    /// App のプロセスで 1 つ（最初に触れたときに `UserDefaults.standard` から読む）。
    public static let shared = UserExtensionStore(defaults: .standard)

    private let defaults: UserDefaults
    private let state: Mutex<UserExtensionMap>

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        self.state = Mutex(Self.load(from: defaults))
    }

    /// 今の一覧。1 回の操作（取り込み・走査・1 冊を開く）は最初に読んだこの値で最後まで通す。
    public var snapshot: UserExtensionMap { state.withLock { $0 } }

    /// 保存された値を 1 項目ずつ読む。形の合わない拡張子・知らない種類・`folder`・標準と重なる拡張子・予約は
    /// **その項目だけ**読み飛ばす（`ViewerSettings.categoryViewerPaths` のように 1 項目の不正で全部消さない）。
    /// 辞書でない値は空。読み飛ばした項目は次の書き込みで消える。
    static func load(from defaults: UserDefaults) -> UserExtensionMap {
        guard let stored = defaults.dictionary(forKey: defaultsKey) else { return [:] }
        var map: UserExtensionMap = [:]
        for (ext, value) in stored {
            guard let raw = value as? String,
                  let category = BookCategory(rawValue: raw),
                  UserExtensionValidator.assignableCategories.contains(category),
                  UserExtensionValidator.isWellFormed(ext),
                  BookCategory.presetCategories[ext] == nil,
                  !UserExtensionValidator.reserved.contains(ext) else { continue }
            map[ext] = category
        }
        return map
    }

    /// 足す。検証 → UserDefaults → スナップショットの差し替え → 通知 `.userExtensionsDidChange` の順。
    /// `category` は `UserExtensionValidator.assignableCategories` のどれか（画面の Picker はそれしか出さない）。
    @discardableResult
    public func add(_ raw: String, category: BookCategory) -> Result<String, UserExtensionError> {
        precondition(UserExtensionValidator.assignableCategories.contains(category), "unassignable category")
        let result: Result<String, UserExtensionError> = state.withLock { map in
            switch UserExtensionValidator.validate(raw, existing: map) {
            case .failure(let error):
                return .failure(error)
            case .success(let ext):
                var next = map
                next[ext] = category
                persist(next)
                map = next
                return .success(ext)
            }
        }
        if case .success = result { postChange() }
        return result
    }

    /// 足した拡張子の種類を変える。足していない拡張子・同じ種類なら何もせず false。
    /// `ext` は `snapshot` の鍵（正規化済み）。
    @discardableResult
    public func setCategory(_ category: BookCategory, for ext: String) -> Bool {
        precondition(UserExtensionValidator.assignableCategories.contains(category), "unassignable category")
        let changed: Bool = state.withLock { map in
            guard let current = map[ext], current != category else { return false }
            var next = map
            next[ext] = category
            persist(next)
            map = next
            return true
        }
        if changed { postChange() }
        return changed
    }

    /// 足した拡張子を消す。足していなければ何もせず false。本は消えない（以後は未知の拡張子＝アーカイブとして扱う）。
    /// `ext` は `snapshot` の鍵（正規化済み）。
    @discardableResult
    public func remove(_ ext: String) -> Bool {
        let changed: Bool = state.withLock { map in
            guard map[ext] != nil else { return false }
            var next = map
            next.removeValue(forKey: ext)
            persist(next)
            map = next
            return true
        }
        if changed { postChange() }
        return changed
    }

    /// 注意: 呼び出しは `state` のロックを持ったまま。UserDefaults への書き込みが同期で走るので、`userBookExtensions` の
    /// 同期的な監視者（KVO・`didChangeNotification`・バインディング）は `snapshot` を読んではならない（同じロックの再取得で落ちる）。
    private func persist(_ map: UserExtensionMap) {
        if map.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(map.mapValues(\.rawValue), forKey: Self.defaultsKey)
        }
    }

    private func postChange() {
        NotificationCenter.default.post(name: .userExtensionsDidChange, object: self)
    }
}

public extension Notification.Name {
    /// G64: 足した拡張子の一覧が変わった（`object` は変えた `UserExtensionStore`）。
    static let userExtensionsDidChange = Notification.Name("app.shelfsmith.stacknest.userExtensionsDidChange")
}
