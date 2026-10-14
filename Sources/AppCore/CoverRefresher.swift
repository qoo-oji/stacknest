// SPDX-License-Identifier: MIT
import Foundation
import ArchiveAdapter
import EPUBAdapter

/// G21 followup Important #2: `extractCoverData` が表紙を作れないと判定した形式
/// （動画・epub・txt/md/rtf 等、フォルダ/アーカイブ/PDF/単独画像のいずれでもないもの）。
/// 呼び出し側（サーバは HTTP 4xx、App はログのみ）でハンドリングする。
public enum CoverRefreshError: Error, Sendable, Equatable {
    case unsupportedFormat
    /// G48-2 Task 6: フォーマット自体は読める（EPUB reader が登録済み）が、その本に表紙画像が
    /// 無い場合。`.unsupportedFormat`（reader 未登録・非対応形式）とは原因が異なるため区別する。
    case noCoverImage
}

/// 単一 book の thumbnail.jpg を抽出 + 保存する純粋ユーティリティ。
/// - 新規 book 追加時 (BookImporter / BookAddCoordinator) 経路
/// - 既存 book の cover_image_name 変更時 (AppState.regenerateThumbnail) 経路
/// の両方で再利用される。
public enum CoverRefresher {
    /// G21 followup Important #2: フォーマット非依存の表紙データ抽出（書き込みは行わない）。
    /// フォルダ/zip 系アーカイブは既存の `ArchiveAdapter.coverExtractor` 経由、単独 PDF は
    /// `PDFBookContent.coverJPEG`（CoverCompression の whole-library ジョブと同じ分岐を再利用）、
    /// 単独画像はファイルをそのまま読む。対応不可な形式は `.unsupportedFormat` を throw する
    /// （zip 内に画像もフォールバック PDF も無い等、既存 extractor が nil を返さず失敗する
    /// ケースはそのまま extractor 側のエラーが伝播する）。
    ///
    /// re-review Important fix: PDF レンダリング（`PDFBookContent.coverJPEG`、同期の CG 描画）と
    /// 単独画像の `Data(contentsOf:)`（同期ファイル I/O）は、フォルダ/zip 系の
    /// `ArchiveAdapter` 実装（`FolderCoverExtractor`/`LibarchiveCoverExtractor`）と違って
    /// 元々どこも off-actor 化していない。呼び出し元が `@MainActor`（App の
    /// `AppState.regenerateThumbnail`）だと、この関数の同期区間はそのまま MainActor 上で
    /// 実行されてしまい、PDF 1 冊ごとに main thread をブロックする（フォルダ一括リマップで
    /// 対象が数百冊になると顕著）。本体全体を `Task.detached` に包み、呼び出し元がどの actor でも
    /// 同期区間がそこに乗らないようにする（`ArchiveAdapter` 側は内部で既に detach しているため
    /// 二重 detach になるが、正当性・安全性上の問題はない）。
    ///
    /// G64: 足した拡張子の本は `addedExtensionCover` の順（StackNest が読む → Quick Look）。標準と未知の拡張子は
    /// 今のまま（Quick Look を使わない）。
    /// - Parameters:
    ///   - userExtensions: 足した拡張子の一覧。既定は呼び出した時点の `shared`（detach の**外**で 1 回だけ読む）。
    ///   - thumbnailer: Quick Look の縮小画像（テストは偽物を渡す）。
    public static func extractCoverData(
        sourceURL: URL,
        preferredName: String?,
        userExtensions: UserExtensionMap = UserExtensionStore.shared.snapshot,
        thumbnailer: any CoverThumbnailing = QuickLookCoverThumbnailer()
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            if let added = BookCategory.userCategory(path: sourceURL.path, userExtensions: userExtensions) {
                return try await addedExtensionCover(sourceURL: sourceURL, category: added,
                                                     preferredName: preferredName, thumbnailer: thumbnailer)
            }
            if sourceURL.pathExtension.lowercased() == "pdf" {
                guard let pdf = PDFBookContent(url: sourceURL) else { throw CoverRefreshError.unsupportedFormat }
                // G54-S4 修正ラウンド2: 「表紙を編集」で選んだページ（`PDFCoverExtractor` が 1 始まりの
                // ページ番号を名前にする）を尊重する。EPUB 分岐と同じ欠陥がここにもあり、preferredName を
                // 一切見ずに常に 1 ページ目を返していた（DB にはページ番号が入るのにサムネイルは変わらない）。
                // `@` 始まりは動画の場面指定（`CoverSource.videoTimePrefix`）等の印なのでページ番号として扱わない。
                // 範囲外・数でないときは 1 ページ目に落ちる。
                let index = preferredName.flatMap { $0.hasPrefix("@") ? nil : Int($0) }.map { $0 - 1 } ?? 0
                let page = (0..<pdf.pageCount).contains(index) ? index : 0
                guard let data = pdf.pageImageData(at: page, maxPixelSize: 1200) else {
                    throw CoverRefreshError.unsupportedFormat
                }
                return data
            }
            // G48: EPUB は契約 `EPUBAdapter.reader` に回す（Washi は AppCore から見えない）。
            // reader 未登録 → 既存の「作れない」経路（unsupportedFormat）。reader はあるがその本に
            // 表紙が無い（G48-2 Task 6） → 原因が異なるので noCoverImage を区別して throw する。
            if sourceURL.pathExtension.lowercased() == "epub" {
                // G54-S4 修正ラウンド1: 「表紙を編集」で選んだ EPUB 内のエントリ（preferredName）は、
                // アーカイブ（zip/cbz 等）と同じく尊重する。`@` 始まりは動画の場面指定
                // （`CoverSource.videoTimePrefix`）等の印であり、アーカイブのエントリ名ではないので除く。
                // 実在を確かめてから使う — `LibarchiveCoverExtractor.extractCoverImage(from:preferredName:)`
                // は該当エントリが無いと natural sort 先頭へ黙って落ちる（LibarchiveCoverExtractor.swift:32-37）。
                // 素通しにすると、名前が古くなった EPUB で「既定の表紙」が「中の適当な 1 枚目」に
                // 劣化してしまう（EPUB の 1 枚目は表紙でないことが多い）。
                if let name = preferredName, !name.hasPrefix("@"),
                   let ex = BookExtractors.coverExtractor(for: sourceURL, userExtensions: userExtensions),
                   let listing = try? await ex.listImageEntries(in: sourceURL), listing.names.contains(name) {
                    return try await ex.extractCoverImage(from: sourceURL, preferredName: name)
                }
                guard let reader = EPUBAdapter.reader else {
                    throw CoverRefreshError.unsupportedFormat
                }
                guard let data = try await reader.coverImageData(url: sourceURL, maxPixelSize: 1200) else {
                    throw CoverRefreshError.noCoverImage
                }
                return data
            }
            // G50: 動画は AVFoundation でフレームを 1 枚取る。`preferredName` が `@t=` なら
            // ユーザーが選んだ場面、それ以外（nil・アーカイブ用のエントリ名）は自動選択。
            // AVFoundation が開けない mkv/webm/avi は従来どおり `.unsupportedFormat`。
            if VideoFrameExtractor.isSupported(url: sourceURL) {
                do {
                    if let seconds = CoverSource.videoTime(from: preferredName) {
                        return try await VideoFrameExtractor.frameData(
                            url: sourceURL, seconds: seconds, maxPixelSize: 1200)
                    }
                    return try await VideoFrameExtractor.autoCoverData(url: sourceURL, maxPixelSize: 1200)
                } catch VideoFrameError.noUsableFrame {
                    // 形式は読めるが、その動画からフレームを 1 枚も作れなかった
                    // （EPUB に表紙が無いときと同じ扱い。「この形式は非対応」とは別）。
                    throw CoverRefreshError.noCoverImage
                } catch {
                    throw CoverRefreshError.unsupportedFormat
                }
            }
            if let extractor = BookExtractors.coverExtractor(for: sourceURL, userExtensions: userExtensions) {
                return try await extractor.extractCoverImage(from: sourceURL, preferredName: preferredName)
            }
            if Self.standaloneImageExtensions.contains(sourceURL.pathExtension.lowercased()) {
                return try Data(contentsOf: sourceURL)
            }
            throw CoverRefreshError.unsupportedFormat
        }.value
    }

    /// G64: 足した拡張子の本の表紙。種類ごとに 1. StackNest が読む → 取れない・投げたら 2. Quick Look。
    /// | 種類 | 1. StackNest が読む |
    /// |---|---|
    /// | アーカイブ | 先頭の画像（`preferredName` があればその画像）→ 無ければ中の PDF の 1 ページ目 |
    /// | 画像 | ImageIO で読み、JPEG（長辺 1200）に書き直す（小さくても必ず） |
    /// | 動画 | AVFoundation（`@t=` があればその場面、無ければ自動選択。拡張子の制限は外す） |
    /// | テキスト | なし（最初から Quick Look） |
    /// どちらも取れなければ `.unsupportedFormat`（取り込みは `coverFailures`、表紙はプレースホルダ）。
    static func addedExtensionCover(sourceURL: URL, category: BookCategory, preferredName: String?,
                                    thumbnailer: any CoverThumbnailing) async throws -> Data {
        if let own = await ownCover(sourceURL: sourceURL, category: category, preferredName: preferredName) {
            return own
        }
        if let thumbnail = await thumbnailer.coverJPEG(for: sourceURL, maxPixelSize: 1200) {
            return thumbnail
        }
        throw CoverRefreshError.unsupportedFormat
    }

    /// 足した拡張子の本を StackNest 自身が読んで作る表紙。投げたときも nil（Quick Look へ進む）。
    private static func ownCover(sourceURL: URL, category: BookCategory, preferredName: String?) async -> Data? {
        do {
            switch category {
            case .archive:
                // 意図的に `BookExtractors` の足したアーカイブの抽出器（libarchive）と同じものを直接使う。
                // あちらの振り分けを変えたら、ここも合わせること。
                // `@` 始まりは動画の場面指定などの印で、アーカイブのエントリ名ではない。
                let name = preferredName.flatMap { $0.hasPrefix("@") ? nil : $0 }
                return try await ArchivePDFFallback.coverData(in: sourceURL, preferredName: name,
                                                              extractor: LibarchiveCoverExtractor(allowsCompressedTar: true))
            case .image:
                return CoverJPEG.fromImageData(try Data(contentsOf: sourceURL), maxPixelSize: 1200)
            case .video:
                if let seconds = CoverSource.videoTime(from: preferredName) {
                    return try await VideoFrameExtractor.frameData(url: sourceURL, seconds: seconds,
                                                                   maxPixelSize: 1200, anyExtension: true)
                }
                return try await VideoFrameExtractor.autoCoverData(url: sourceURL, maxPixelSize: 1200, anyExtension: true)
            case .text, .folder:
                return nil
            }
        } catch {
            return nil
        }
    }

    /// `BookCategory.classify(path:)` の `.image` 判定と同じ拡張子集合（Sources/AppCore/BookCategory.swift）。
    private static let standaloneImageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"]

    /// re-review Important fix: `CoverImageResizer.resizeJPEG` は CGImageSource デコード + JPEG
    /// 再エンコードという相応に重い CPU 処理。`extractCoverData` 同様、呼び出し元の actor
    /// （MainActor 含む）をブロックしないよう detach する。
    public static func resizeCoverDataOffMain(_ data: Data, maxPixelSize: Int) async -> Data {
        await Task.detached(priority: .userInitiated) {
            CoverImageResizer.resizeJPEG(data, maxPixelSize: maxPixelSize)
        }.value
    }

    /// `Thumbnails/<bookID>/thumbnail.jpg` に表紙画像を保存する。
    /// - Parameters:
    ///   - bookID: 対象 book の DB id
    ///   - sourceURL: アーカイブ or フォルダの絶対 URL
    ///   - preferredName: 手動指定の cover_image_name (nil = 自動先頭)
    ///   - thumbnailsDirURL: bundle 内の Thumbnails ディレクトリ URL
    ///   - extractor: 該当 source に対応する CoverImageExtractor (caller が dispatch 済み)
    public static func regenerate(
        bookID: Int,
        sourceURL: URL,
        preferredName: String?,
        thumbnailsDirURL: URL,
        extractor: any CoverImageExtractor
    ) async throws {
        let imageData = try await extractor.extractCoverImage(from: sourceURL, preferredName: preferredName)
        let bookDir = thumbnailsDirURL.appendingPathComponent("\(bookID)")
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        let thumbURL = bookDir.appendingPathComponent("thumbnail.jpg")
        // Phase 2.5h B19: storage 段階で UI 上限 px (1200) へ resize して保存。
        // 元画像が 1200 px 以下ならそのまま (品質維持)。
        let resized = CoverImageResizer.resizeJPEG(imageData, maxPixelSize: 1200)
        try resized.write(to: thumbURL)
    }

    /// 外部画像データから直接 thumbnail.jpg を生成する（アーカイブ抽出なし・G4a 外部表紙）。
    public static func regenerateFromImageData(bookID: Int, imageData: Data, thumbnailsDirURL: URL) throws {
        let bookDir = thumbnailsDirURL.appendingPathComponent("\(bookID)")
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        let thumbURL = bookDir.appendingPathComponent("thumbnail.jpg")
        let resized = CoverImageResizer.resizeJPEG(imageData, maxPixelSize: 1200)
        try resized.write(to: thumbURL)
    }
}
