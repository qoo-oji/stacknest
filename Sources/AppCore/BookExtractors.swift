// SPDX-License-Identifier: MIT
import Foundation
import ArchiveAdapter

/// G64: 表紙・取り込みの抽出器の振り分け（足した拡張子を含む）。
///
/// `ArchiveAdapter.coverExtractor(for:)`・`importExtractor(for:)` は標準の拡張子だけを知っている
/// （依存は AppCore → ArchiveAdapter の向きなので、足した一覧をそこへ入れられない）。ここでは ArchiveAdapter の
/// 結果があればそれを返し、無くて足した一覧で `.archive` の拡張子なら `LibarchiveCoverExtractor` を返す。
/// **ArchiveAdapter の振り分けを直接呼ぶのは、ここと ArchiveAdapter の中だけ**（リモートの本の
/// `DetailPaneView.canEditCover(remoteFileExtension:)` は標準の表だけで決めるので例外）。
public enum BookExtractors {
    /// 表紙候補を選ぶ用（「表紙を編集」・`cover-candidates`／`entry-image`・表紙の作り直し）。
    public static func coverExtractor(for url: URL, userExtensions: UserExtensionMap) -> CoverImageExtractor? {
        if let standard = ArchiveAdapter.coverExtractor(for: url) { return standard }
        return addedArchiveExtractor(for: url, userExtensions: userExtensions)
    }

    /// 取り込み用（`BookImporter`）。EPUB・PDF は専用の道で扱うので返さない（ArchiveAdapter と同じ）。
    public static func importExtractor(for url: URL, userExtensions: UserExtensionMap) -> CoverImageExtractor? {
        if let standard = ArchiveAdapter.importExtractor(for: url) { return standard }
        return addedArchiveExtractor(for: url, userExtensions: userExtensions)
    }

    private static func addedArchiveExtractor(for url: URL, userExtensions: UserExtensionMap) -> CoverImageExtractor? {
        BookCategory.userCategory(path: url.path, userExtensions: userExtensions) == .archive
            ? LibarchiveCoverExtractor() : nil
    }
}
