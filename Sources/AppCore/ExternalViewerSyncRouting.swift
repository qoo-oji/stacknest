// SPDX-License-Identifier: MIT
import Foundation
import LibraryServerAPI

/// G60: 本を参照ファイル（`.stacknestbook`）で外部ビューアへ渡すかの判断（spec §5.5）。
public enum ExternalViewerSyncRouting {
    /// ローカルの書庫の本。今の `ViewerChoice` で画像側に従う本（アーカイブ・画像・フォルダ・PDF）を、
    /// 画像を外部ビューアで開く設定かつ同期 ON のときだけ参照ファイルにする。EPUB は EPUB 側の設定に
    /// 従うので対象外（ローカルの EPUB は今までどおり）。
    public static func localOpensByReference(path: String, useBuiltInImageViewer: Bool, syncEnabled: Bool) -> Bool {
        guard syncEnabled, !useBuiltInImageViewer, !path.isEmpty else { return false }
        return ViewerChoice.viewerSwitch(forPath: path) == .image
    }

    /// リモートの本の一次判定（manifest を取る前）。false ならいつもの内蔵ビューア。
    /// 動画とテキスト（txt・md・rtf）は外す。EPUB と filename の無い本は manifest を見てから決める。
    public static func remoteMayOpenByReference(filename: String?, useBuiltInImageViewer: Bool, syncEnabled: Bool) -> Bool {
        guard syncEnabled, !useBuiltInImageViewer else { return false }
        guard let filename else { return true }
        return BookCategory.builtInViewerSupport(filename: filename) == .supported
    }

    /// リモートの本の最終判定。ページで読む本（テキスト EPUB でも動画でもなく、1 ページ以上ある）だけ。
    public static func remoteOpensByReference(filename: String?, manifest: ManifestDTO,
                                              useBuiltInImageViewer: Bool, syncEnabled: Bool) -> Bool {
        guard remoteMayOpenByReference(filename: filename, useBuiltInImageViewer: useBuiltInImageViewer,
                                       syncEnabled: syncEnabled) else { return false }
        guard manifest.pageCount > 0, manifest.format != "epub", manifest.format != "video" else { return false }
        return RemoteEPUBRouting.route(filename: filename, manifestFormat: manifest.format) == .pages
    }
}
