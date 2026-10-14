// SPDX-License-Identifier: MIT
import Foundation
import OSLog
import ArchiveAdapter

/// G64: アーカイブの表紙の「先頭の画像 → 無ければ中の PDF の 1 ページ目」を 1 か所に置く。
/// 取り込み（`BookImporter`・標準のアーカイブも今どおりここを通る）と、足した拡張子の表紙の作り直し
/// （`CoverRefresher.extractCoverData` の足した拡張子の道）が使う。標準のアーカイブの作り直しが中の PDF を
/// 見ないのは今のまま（spec §11 の 5）。
enum ArchivePDFFallback {
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "ArchivePDFFallback")

    /// 中の最初の PDF（自然順）を一時ファイルに書いて開き、ページ数と 1 ページ目の JPEG（長辺 1200）を返す。
    /// PDF が無い・開けない・書けないなら nil。一時ファイルは必ず消す。
    static func embeddedPDF(in url: URL, extractor: any CoverImageExtractor) async -> (pageCount: Int, cover: Data?)? {
        guard let pdfData = try? await extractor.extractFirstPDFData(in: url) else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try pdfData.write(to: tmp)
        } catch {
            logger.warning("PDF fallback temp-write failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
        guard let content = PDFBookContent(url: tmp) else { return nil }
        return (content.pageCount, content.coverJPEG(maxPixelSize: 1200))
    }

    /// 先頭の画像（`preferredName` があればその画像。無ければ自然順の先頭）→ 画像が 1 枚も無ければ中の PDF の
    /// 1 ページ目。どちらも無ければ `noImageEntry` を投げる。開けない・途中で壊れているなどは抽出器のエラーのまま。
    static func coverData(in url: URL, preferredName: String?, extractor: any CoverImageExtractor) async throws -> Data {
        do {
            return try await extractor.extractCoverImage(from: url, preferredName: preferredName)
        } catch let error as ArchiveAdapterError {
            guard case .noImageEntry = error else { throw error }
            if let cover = await embeddedPDF(in: url, extractor: extractor)?.cover { return cover }
            throw error
        }
    }
}
