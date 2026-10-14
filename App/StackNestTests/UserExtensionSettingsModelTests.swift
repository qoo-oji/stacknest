// SPDX-License-Identifier: MIT
import Foundation
import Testing
import AppCore
@testable import StackNest

/// G64: 設定のシート「拡張子と種類」のモデル（spec §6.8・§6.9）。suite の store だけを使う
/// （App のテストは本物の UserDefaults の上で動くので `UserExtensionStore.shared` に触れない）。
@MainActor
@Suite("G64: 拡張子と種類の設定")
struct UserExtensionSettingsModelTests {
    private func makeModel() -> (UserExtensionSettingsModel, UserExtensionStore, () -> Void) {
        let name = "g64-model-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let store = UserExtensionStore(defaults: defaults)
        return (UserExtensionSettingsModel(store: store), store, { defaults.removePersistentDomain(forName: name) })
    }

    @Test("足す: 正規化して足し、欄を空にする・種類は選んだもの")
    func addNormalizesAndClears() {
        let (model, store, cleanup) = makeModel(); defer { cleanup() }
        model.draft = " *.TGZ "
        #expect(model.add())
        #expect(model.draft.isEmpty)
        #expect(model.errorText == nil)
        model.draft = "docx"
        model.draftCategory = .text
        #expect(model.add())
        #expect(store.snapshot == ["tgz": .archive, "docx": .text])
        #expect(model.addedRows.map(\.ext) == ["docx", "tgz"], "拡張子の順")
        #expect(model.addedRows.allSatisfy { !$0.isStandard })
    }

    @Test("足せない理由の文言（日本語）・欄の中身は残す", arguments: [
        ("", "拡張子を入力してください。"),
        ("a.b", "拡張子に使えるのは半角の英数字・ハイフン・アンダースコアで、16 文字までです。"),
        ("abcdefghijklmnopq", "拡張子に使えるのは半角の英数字・ハイフン・アンダースコアで、16 文字までです。"),
        ("zip", "「.zip」は標準の拡張子です（アーカイブ）。"),
        ("CBT", "「.cbt」は標準の拡張子です（アーカイブ）。"),
        ("epub", "「.epub」は標準の拡張子です（電子書籍）。"),
        ("pdf", "「.pdf」は標準の拡張子です（テキスト）。"),
        ("stacknest", "「.stacknest」は StackNest が使うため追加できません。"),
    ])
    func errorMessages(raw: String, message: String) {
        let (model, _, cleanup) = makeModel(); defer { cleanup() }
        model.draft = raw
        #expect(!model.add())
        #expect(model.errorText == message)
        #expect(model.draft == raw)
    }

    @Test("2 回目と 101 個目の文言")
    func duplicateAndLimitMessages() {
        let (model, store, cleanup) = makeModel(); defer { cleanup() }
        model.draft = "tgz"; model.add()
        model.draft = ".tgz"
        #expect(!model.add())
        #expect(model.errorText == "「.tgz」はもう追加されています。")
        for i in 0..<99 { store.add("x\(i)", category: .archive) }
        model.draft = "y"
        #expect(!model.add())
        #expect(model.errorText == "追加できる拡張子は 100 個までです。")
    }

    @Test("種類を変える・消す（ほかの store の変更も通知で読み直す）")
    func changeAndRemove() {
        let (model, store, cleanup) = makeModel(); defer { cleanup() }
        model.draft = "tgz"; model.add()
        model.setCategory(.text, for: "tgz")
        #expect(store.snapshot == ["tgz": .text])
        #expect(model.addedRows.first?.label == "テキスト")
        model.remove("tgz")
        #expect(store.snapshot.isEmpty)
        #expect(model.addedRows.isEmpty)
        // 画面の外（同じ store の別の書き手）の変更も、知らせで読み直す。
        store.add("avif", category: .image)
        #expect(model.addedRows.map(\.ext) == ["avif"])
    }

    @Test("標準の 29 行: 種類の順・操作なし・epub は電子書籍・pdf はテキスト・cbt と tar はアーカイブ")
    func standardRows() {
        let rows = UserExtensionSettingsModel.standardRows
        #expect(rows.count == 29)
        #expect(rows.allSatisfy { $0.isStandard })
        #expect(rows.prefix(8).map(\.ext) == ["7z", "cb7", "cbr", "cbt", "cbz", "rar", "tar", "zip"])
        #expect(rows.first { $0.ext == "epub" }?.label == "電子書籍")
        #expect(rows.first { $0.ext == "pdf" }?.label == "テキスト")
        #expect(rows.first { $0.ext == "cbt" }?.label == "アーカイブ")
        #expect(rows.first { $0.ext == "tar" }?.label == "アーカイブ")
        // 種類の順（アーカイブ 8・画像 10・動画 6・テキスト 5）。
        let counts = UserExtensionValidator.assignableCategories.map { c in rows.filter { $0.category == c }.count }
        #expect(counts == [8, 10, 6, 5])
        let firstOfEach = UserExtensionValidator.assignableCategories.compactMap { c in rows.firstIndex { $0.category == c } }
        #expect(firstOfEach == [0, 8, 18, 24])
    }

    @Test("種類ごとの行の説明に足した拡張子が付く")
    func hints() {
        let (model, store, cleanup) = makeModel(); defer { cleanup() }
        #expect(model.hint(for: .archive) == ".zip / .cbz / .rar / .cbr / .7z / .cbt / .tar")
        store.add("tgz", category: .archive)
        store.add("djvu", category: .archive)
        store.add("docx", category: .text)
        #expect(model.hint(for: .archive) == ".zip / .cbz / .rar / .cbr / .7z / .cbt / .tar + .djvu / .tgz")
        #expect(model.hint(for: .text) == ".pdf / .txt / .md / .rtf + .docx")
        #expect(model.hint(for: .video) == ".mp4 / .mov / .avi / .mkv / .webm / .m4v")
    }

    @Test("手で編集した 101 個でも全行を出し、足すのだけ止める")
    func moreThanTheLimitStillDisplaysEveryRow() {
        let name = "g64-model-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var raw: [String: String] = [:]
        for i in 0..<101 { raw[String(format: "x%03d", i)] = BookCategory.archive.rawValue }
        defaults.set(raw, forKey: UserExtensionStore.defaultsKey)
        let model = UserExtensionSettingsModel(store: UserExtensionStore(defaults: defaults))
        #expect(model.addedRows.count == 101)
        model.draft = "y"
        #expect(!model.add())
        #expect(model.errorText == "追加できる拡張子は 100 個までです。")
        #expect(model.addedRows.count == 101)
    }
}
