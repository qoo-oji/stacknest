// SPDX-License-Identifier: MIT
import Foundation
import Observation
import AppCore

/// G64: 設定 ▸ 表示 ▸ 外部ビューア の「拡張子」と、そのシート「拡張子と種類」の状態（spec §6.8）。
/// `UserExtensionStore` を読み、`.userExtensionsDidChange` で読み直す。`UserExtensionError` を文言に写すのもここ。
/// テストは suite の store を渡して作る（App のテストは本物の UserDefaults の上で動くので `shared` を使わない）。
@Observable
@MainActor
final class UserExtensionSettingsModel {
    /// 一覧の 1 行。
    struct Row: Identifiable, Equatable {
        let ext: String
        let category: BookCategory
        /// 種類の表示（一覧とエラーで共通。`epub` は電子書籍）。
        let label: String
        let isStandard: Bool
        var id: String { ext }
    }

    private let store: UserExtensionStore
    /// 足した拡張子（store のスナップショット）。
    private(set) var added: UserExtensionMap
    /// 足す行の入力欄。
    var draft = ""
    /// 足す行の種類（既定はアーカイブ）。
    var draftCategory: BookCategory = .archive
    /// 足せなかった理由（欄の下に赤で出す）。足せたら nil。
    private(set) var errorText: String?
    @ObservationIgnored private var observer: ObserverToken?

    init(store: UserExtensionStore = .shared) {
        self.store = store
        self.added = store.snapshot
        let token = NotificationCenter.default.addObserver(
            forName: .userExtensionsDidChange, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        observer = ObserverToken(token)
    }

    func reload() {
        added = store.snapshot
    }

    /// 足した拡張子の行（拡張子の順）。
    var addedRows: [Row] {
        added.keys.sorted().map { ext in
            let category = added[ext] ?? .archive
            return Row(ext: ext, category: category, label: Self.categoryLabel(ext: ext, category: category), isStandard: false)
        }
    }

    /// 標準の 29 行（種類の順＝アーカイブ・画像・動画・テキスト、その中は拡張子の順）。操作は無い。
    static var standardRows: [Row] {
        UserExtensionValidator.assignableCategories.flatMap { category in
            BookCategory.presetCategories.filter { $0.value == category }.keys.sorted().map { ext in
                Row(ext: ext, category: category, label: categoryLabel(ext: ext, category: category), isStandard: true)
            }
        }
    }

    /// 足す。通れば欄を空にして true、通らなければ理由を `errorText` に入れ、欄の中身は残して false。
    @discardableResult
    func add() -> Bool {
        switch store.add(draft, category: draftCategory) {
        case .success:
            draft = ""
            errorText = nil
            reload()
            return true
        case .failure(let error):
            errorText = Self.message(for: error)
            return false
        }
    }

    func setCategory(_ category: BookCategory, for ext: String) {
        store.setCategory(category, for: ext)
        reload()
    }

    /// 消す（確認は出さない。本は消えず、足し直せば元に戻る）。
    func remove(_ ext: String) {
        store.remove(ext)
        reload()
    }

    /// 設定の種類ごとの行の説明。標準の拡張子の後ろに、その種類に足した拡張子を付ける
    /// （例 `.zip / … / .tar + .tgz`）。足した部分は記号と拡張子だけなので訳さない。
    func hint(for category: BookCategory) -> String {
        let mine = added.filter { $0.value == category }.keys.sorted()
        guard !mine.isEmpty else { return category.extensionsHint }
        return category.extensionsHint + " + " + mine.map { "." + $0 }.joined(separator: " / ")
    }

    /// 種類の表示。`epub` は電子書籍（外部ビューアの行と一致させる）、ほかは種類の名前（pdf はテキスト）。
    static func categoryLabel(ext: String, category: BookCategory) -> String {
        ext == "epub" ? String(localized: "電子書籍") : category.displayName
    }

    /// 足せない理由の文言。
    static func message(for error: UserExtensionError) -> String {
        switch error {
        case .empty:
            return String(localized: "拡張子を入力してください。")
        case .invalidFormat:
            return String(localized: "拡張子に使えるのは半角の英数字・ハイフン・アンダースコアで、\(UserExtensionValidator.maxLength) 文字までです。")
        case .standard(let ext):
            let label = categoryLabel(ext: ext, category: BookCategory.presetCategories[ext] ?? .archive)
            return String(localized: "「.\(ext)」は標準の拡張子です（\(label)）。")
        case .reserved(let ext):
            return String(localized: "「.\(ext)」は StackNest が使うため追加できません。")
        case .alreadyAdded(let ext):
            return String(localized: "「.\(ext)」はもう追加されています。")
        case .limitReached:
            return String(localized: "追加できる拡張子は \(UserExtensionValidator.maxCount) 個までです。")
        }
    }
}

/// 知らせの購読。このオブジェクトが消えたら外す（`@MainActor` のクラスの deinit から触らずに済むように分けた）。
private final class ObserverToken: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
