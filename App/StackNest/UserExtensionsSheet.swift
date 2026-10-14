// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

/// G64: 設定のシート「拡張子と種類」（spec §6.8）。変更はその場で保存・反映する（取り消しは無い）。
struct UserExtensionsSheet: View {
    @Bindable var model: UserExtensionSettingsModel
    @Environment(\.dismiss) private var dismiss

    private let extensionColumn: CGFloat = 150
    private let categoryColumn: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("拡張子と種類")
                .font(.headline)
            Text("足した拡張子のファイルは、選んだ種類と同じに扱います（追加・内蔵か外部か・外部ビューア）。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("StackNest が中身を読めないときは、その種類の外部ビューアで開き、表紙には Quick Look の縮小画像を使います。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("拡張子（例: avif）", text: $model.draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: extensionColumn)
                    .onSubmit { model.add() }
                categoryPicker(selection: $model.draftCategory)
                Button("追加") { model.add() }
            }
            if let error = model.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text(String(localized: "settings.extensions.column.extension", defaultValue: "拡張子"))
                    .frame(width: extensionColumn, alignment: .leading)
                Text(String(localized: "settings.extensions.category", defaultValue: "種類"))
                    .frame(width: categoryColumn, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 8)

            List {
                if model.addedRows.isEmpty {
                    Text("足した拡張子はまだありません。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.addedRows) { row in
                    HStack(spacing: 8) {
                        Text(verbatim: "." + row.ext)
                            .frame(width: extensionColumn, alignment: .leading)
                        categoryPicker(selection: Binding(
                            get: { row.category },
                            set: { model.setCategory($0, for: row.ext) }))
                        Spacer()
                        Button {
                            model.remove(row.ext)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "settings.extensions.remove", defaultValue: "削除"))
                        .accessibilityLabel(Text(String(localized: "settings.extensions.remove", defaultValue: "削除")))
                    }
                }
                ForEach(UserExtensionSettingsModel.standardRows) { row in
                    HStack(spacing: 8) {
                        Text(verbatim: "." + row.ext)
                            .frame(width: extensionColumn, alignment: .leading)
                        Text(verbatim: row.label)
                            .frame(width: categoryColumn, alignment: .leading)
                        Text("標準")
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(height: 260)

            Text("足した拡張子を消しても、登録済みの本は消えません（アーカイブとして扱われます）。もう一度足すと元に戻ります。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("足す前に登録した本の表紙は「表紙を再生成」で作り直せます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                // Return は入力欄の「追加」に使うので、既定のボタンにはしない（Esc で閉じる）。
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// 振り分け先の 4 つ（アーカイブ・画像・動画・テキスト）。
    private func categoryPicker(selection: Binding<BookCategory>) -> some View {
        Picker(String(localized: "settings.extensions.category", defaultValue: "種類"), selection: selection) {
            ForEach(UserExtensionValidator.assignableCategories, id: \.self) { category in
                Text(verbatim: category.displayName).tag(category)
            }
        }
        .labelsHidden()
        .frame(width: categoryColumn)
    }
}
