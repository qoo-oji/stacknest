// SPDX-License-Identifier: MIT
import Foundation

/// G64: 足した拡張子の本を、StackNest がページとして読めるか（spec §6.5 (c)）。
/// G60 の参照ファイルで渡す前に、足した拡張子の本だけ確かめる（読めない本を渡すと、ビューアは
/// 127.0.0.1 の口から manifest を取れず、15 秒後に「読み込んでいません」のお知らせになる）。
public enum BookReadability {
    /// `BookContentFactory.make` が通り、1 ページ以上ある。
    public static func canServePages(path: String, userExtensions: UserExtensionMap) async -> Bool {
        guard let content = try? BookContentFactory.make(path: path, userExtensions: userExtensions),
              let pageCount = try? await content.pageCount else { return false }
        return pageCount > 0
    }
}
