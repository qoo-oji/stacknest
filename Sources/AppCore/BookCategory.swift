// SPDX-License-Identifier: MIT
import Foundation
import StackNestL10n

/// HelperLauncher が viewer 選択に使う file category。
/// B18 (bookType 自動分類, Phase 2.5f) の DB 属性とは目的が異なるため独立 enum。
public enum BookCategory: String, CaseIterable, Codable, Sendable {
    case archive, image, folder, video, text

    /// UI 表示用ラベル (Settings 画面)
    public var displayName: String {
        switch self {
        case .archive: return L10n.text("アーカイブ")
        case .image:   return L10n.text("画像")
        case .folder:  return L10n.text("フォルダ")
        case .video:   return L10n.text("動画")
        case .text:    return L10n.text("テキスト")
        }
    }

    /// UI 補足表示 (拡張子例)
    public var extensionsHint: String {
        switch self {
        case .archive: return ".zip / .cbz / .rar / .cbr / .7z / .cbt / .tar"
        case .image:   return ".jpg / .png / .gif / .webp / .heic / etc"
        case .folder:  return L10n.text("(ディレクトリ書籍)")
        case .video:   return ".mp4 / .mov / .avi / .mkv / .webm / .m4v"
        case .text:    return ".pdf / .txt / .md / .rtf"
        }
    }

    /// G64: 標準の拡張子 → 種類（29 個）。分類・`supportedExtensions`・足すときの衝突の判定の正。
    /// epub は電子書籍の特別扱い、pdf は画像側のスイッチ（どちらも種類は `.text`・`ViewerChoice` を参照）。
    /// G64 で `cbt`・`tar` をアーカイブに加えた（作者の決定 2026-10-08）。
    public static let presetCategories: [String: BookCategory] = {
        var table: [String: BookCategory] = [:]
        for ext in ["zip", "cbz", "rar", "cbr", "7z", "cb7", "cbt", "tar"] { table[ext] = .archive }
        for ext in ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"] { table[ext] = .image }
        for ext in ["mp4", "mov", "avi", "mkv", "webm", "m4v"] { table[ext] = .video }
        for ext in ["pdf", "epub", "txt", "md", "rtf"] { table[ext] = .text }
        return table
    }()

    /// path をもとに category を判定する（便宜版。足した一覧は `UserExtensionStore.shared` の今の値）。
    /// 1 回の操作の中で何度も分類するときは、一覧を 1 回読んで `classify(path:userExtensions:)` に渡す。
    public static func classify(path: String) -> BookCategory {
        classify(path: path, userExtensions: UserExtensionStore.shared.snapshot)
    }

    /// path をもとに category を判定する（G64 の正）。
    /// 1. ディレクトリならフォルダ（拡張子より先。FileManager.fileExists(atPath:isDirectory:) で見る）
    /// 2. 標準の表にあればその種類（標準が常に勝つ）
    /// 3. 足した一覧にあればその種類（`folder` は無視）
    /// 4. どれでもなければアーカイブ（Stackroom が zip 中心だった経緯による fallback。監視フォルダ・CLI で入った本がこれで動いている）
    public static func classify(path: String, userExtensions: UserExtensionMap) -> BookCategory {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return .folder
        }
        let ext = (path as NSString).pathExtension.lowercased()
        if let preset = presetCategories[ext] { return preset }
        if let added = userExtensions[ext], added != .folder { return added }
        return .archive
    }

    /// G64: 足した拡張子のファイルなら、その種類。ディレクトリ・標準の拡張子・足していない拡張子は nil。
    /// 「足した拡張子の本だけ」振る舞いを変える箇所（表紙・読めるかの確かめ・破損チェックの「対象外」）が使う。
    public static func userCategory(path: String, userExtensions: UserExtensionMap) -> BookCategory? {
        guard !userExtensions.isEmpty else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        guard presetCategories[ext] == nil, let added = userExtensions[ext], added != .folder else { return nil }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return nil }
        return added
    }

    /// Phase 2.5g+h+i fixup v1: NSOpenPanel / DropDelegate などの caller が「対応拡張子」を
    /// 単一ソースから引けるように。標準の表（`presetCategories`）の鍵で、未知の拡張子の
    /// archive fallback は含まない (= 真に「対応している」拡張子のみ)。
    public static let supportedExtensions: Set<String> = Set(presetCategories.keys)

    /// G64: ドロップと読み込みのパネルが受け付ける拡張子 = 標準 ∪ 足した一覧。
    public static func registrableExtensions(userExtensions: UserExtensionMap) -> Set<String> {
        supportedExtensions.union(userExtensions.keys)
    }
}

/// CodingKeyRepresentable で String dict として encode させる (JSONEncoder の object 形式を強制)。
/// これがないと `[BookCategory: String]` は unkeyed array (`["archive","/path",...]`) で encode される。
extension BookCategory: CodingKeyRepresentable {}

extension BookCategory {
    public enum BuiltInViewerSupport: Equatable { case supported, unsupportedVideo, unsupportedDocument }
    /// 拡張子だけで内蔵ビューア対応可否を返す（BookContentFactory.make の対応集合と対称）。
    /// **リモートの本の filename 用・標準の表だけで決める**（G64）。呼び出し元はリモートの本だけで、手元の
    /// 足した一覧はサーバの一覧と一致するとは限らない。手元の一覧で弾くと、サーバでは読める本まで開けなくなる。
    /// 未知の拡張子（サーバで足した拡張子を含む）は `.supported` で通し、サーバの manifest で決める。
    public static func builtInViewerSupport(filename: String) -> BuiltInViewerSupport {
        switch (filename as NSString).pathExtension.lowercased() {
        case "mp4", "mov", "avi", "mkv", "webm", "m4v": return .unsupportedVideo
        case "txt", "md", "rtf":                        return .unsupportedDocument
        default:                                        return .supported   // archive/image/pdf/epub/未知（G48-2: epub 対応）
        }
    }
}
