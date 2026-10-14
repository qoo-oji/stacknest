// SPDX-License-Identifier: MIT
import Foundation
import OSLog
import Carchive

/// Extracts the first image entry from a zip / cbz / cbr / rar / 7z / tar (cbt) archive using libarchive.
/// 開く形式は `LibarchiveFormats.enable(_:for:)` の 1 か所で決める（G64）。
/// Image entries are detected by file extension (jpg/jpeg/png/gif/webp/bmp).
public struct LibarchiveCoverExtractor: CoverImageExtractor {
    // Phase 2.6b-2 T-C fixup: BookCategory.supportedExtensions に含まれる全画像拡張子に揃える。
    // heic/heif/tiff/tif/webp/avif は macOS NSImage で描画可能。
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp",
        "heic", "heif", "tiff", "tif", "avif"
    ]

    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "LibarchiveCoverExtractor")

    /// G64: tar を歩く仕事の上限（テストは小さな値を渡す）。
    private let walkLimits: TarWalkLimits

    /// G64: gzip で包んだ tar を読んでよいか。**ユーザーがアーカイブとして足した拡張子のときだけ true**（`BookExtractors` が決める）。
    private let allowsCompressedTar: Bool

    public init(walkLimits: TarWalkLimits = .standard, allowsCompressedTar: Bool = false) {
        self.walkLimits = walkLimits
        self.allowsCompressedTar = allowsCompressedTar
    }

    public func extractCoverImage(from url: URL) async throws -> Data {
        let limits = walkLimits
        let gz = allowsCompressedTar
        return try await Task.detached(priority: .userInitiated) {
            try Self.extract(from: url, limits: limits, compressedTar: gz)
        }.value
    }

    public func extractCoverImage(from url: URL, preferredName: String?) async throws -> Data {
        let limits = walkLimits
        let gz = allowsCompressedTar
        return try await Task.detached(priority: .userInitiated) {
            let listing = try Self.enumerateImageEntries(from: url, limits: limits, compressedTar: gz)
            guard !listing.names.isEmpty else { throw ArchiveAdapterError.noImageEntry(url) }
            let sorted = listing.names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let target: String
            if let pref = preferredName, sorted.contains(pref) {
                target = pref
            } else {
                // preferredName が nil または該当エントリなし → natural sort 先頭にフォールバック
                target = sorted[0]
            }
            return try Self.extractByName(from: url, targetName: target, limits: limits, compressedTar: gz)
        }.value
    }

    public func listImageEntries(in url: URL) async throws -> ArchiveListing {
        let limits = walkLimits
        let gz = allowsCompressedTar
        return try await Task.detached(priority: .userInitiated) {
            let listing = try Self.enumerateImageEntries(from: url, limits: limits, compressedTar: gz)
            return ArchiveListing(
                names: listing.names.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                truncated: listing.truncated
            )
        }.value
    }

    public func countImageEntries(in url: URL) async throws -> ArchiveEntryCount {
        let limits = walkLimits
        let gz = allowsCompressedTar
        return try await Task.detached(priority: .userInitiated) {
            try Self.count(from: url, limits: limits, compressedTar: gz)
        }.value
    }

    /// Phase 2.5i: アーカイブ内の最初の PDF entry (natural sort 順) を Data として返す。
    /// PDF が無ければ nil。enumerate して name を natural sort し、先頭のエントリを再オープンで読み出す。
    /// 構造は `extract(from:)` (画像版) と並列 — predicate を `.pdf` 拡張子に置き換えただけ。
    /// 読み出し失敗時は OSLog warning を残して nil を返す (caller は「PDF なし」と区別できない)。
    public func extractFirstPDFData(in url: URL) async throws -> Data? {
        let limits = walkLimits
        let gz = allowsCompressedTar
        return try await Task.detached(priority: .userInitiated) {
            let names = try Self.enumeratePDFEntries(from: url, limits: limits, compressedTar: gz)
            guard !names.isEmpty else { return nil }
            let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            do {
                return try Self.extractByName(from: url, targetName: sorted[0], limits: limits, compressedTar: gz)
            } catch {
                Self.logger.warning("extractFirstPDFData: read failed for \(sorted[0], privacy: .public) in \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
    }

    /// 指定 entry 名 (呼び出し側が listImageEntries で得た natural sort 済みの名前) の画像 Data を返す。
    /// entry が存在しなければ ArchiveAdapterError.noImageEntry を throw。
    /// 内蔵ビューア (Phase 2.6b) のページ取得で使用。
    public func imageData(in url: URL, entryName: String) async throws -> Data {
        let limits = walkLimits
        let gz = allowsCompressedTar
        return try await Task.detached(priority: .userInitiated) {
            try Self.extractByName(from: url, targetName: entryName, limits: limits, compressedTar: gz)
        }.value
    }

    /// Pass 1 (PDF 版) — open the archive and collect all `.pdf` entry names.
    private static func enumeratePDFEntries(from url: URL, limits: TarWalkLimits, compressedTar: Bool) throws -> [String] {
        guard let archive = archive_read_new() else {
            throw ArchiveAdapterError.archiveUnreadable(url, reason: "archive_read_new failed")
        }
        defer { archive_read_free(archive) }

        LibarchiveFormats.enable(archive, for: url, allowsCompressedTar: compressedTar)

        let status = url.path.withCString { cPath in
            archive_read_open_filename(archive, cPath, 16384)
        }
        if status != ARCHIVE_OK {
            let msg = errorMessage(archive)
            throw ArchiveAdapterError.archiveUnreadable(url, reason: msg.isEmpty ? "open failed" : msg)
        }

        var names: [String] = []
        var entry: OpaquePointer?
        var budget = TarWalkBudget(url: url, limits: limits)
        while true {
            let r = archive_read_next_header(archive, &entry)
            if r == ARCHIVE_EOF { break }
            // G64: tar を歩く量の上限を超えたら、ヘッダが読めなくなったのと同じに扱う。
            let overBudget = budget.exceeds(archive, header: r, entry: entry)
            if (r != ARCHIVE_OK && r != ARCHIVE_WARN) || overBudget {
                // G26: 途中打ち切り。集めた分を返す（0 件なら throw）。
                if names.isEmpty {
                    let msg = overBudget ? TarWalkBudget.exceededReason : errorMessage(archive)
                    throw ArchiveAdapterError.archiveUnreadable(url, reason: msg.isEmpty ? "read header failed" : msg)
                }
                return names
            }
            guard let entry = entry else { archive_read_data_skip(archive); continue }
            guard let cName = archive_entry_pathname(entry) else { archive_read_data_skip(archive); continue }
            let name = String(cString: cName)
            archive_read_data_skip(archive)
            if name.hasSuffix("/") { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            if ext == "pdf" {
                names.append(name)
            }
        }
        return names
    }

    /// Safely read the libarchive error string; returns empty string if nil.
    private static func errorMessage(_ archive: OpaquePointer) -> String {
        guard let cStr = archive_error_string(archive) else { return "" }
        return String(cString: cStr)
    }

    private static func extract(from url: URL, limits: TarWalkLimits, compressedTar: Bool) throws -> Data {
        // Pass 1: enumerate all image entry names
        let listing = try enumerateImageEntries(from: url, limits: limits, compressedTar: compressedTar)
        guard !listing.names.isEmpty else { throw ArchiveAdapterError.noImageEntry(url) }
        // Natural sort (localizedStandardCompare): page2 < page10
        let sorted = listing.names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let target = sorted[0]

        // Pass 2: extract the data for the target entry by name
        return try extractByName(from: url, targetName: target, limits: limits, compressedTar: compressedTar)
    }

    /// Pass 1 — open the archive and collect all image-extension entry names.
    private static func enumerateImageEntries(from url: URL, limits: TarWalkLimits, compressedTar: Bool) throws -> ArchiveListing {
        guard let archive = archive_read_new() else {
            throw ArchiveAdapterError.archiveUnreadable(url, reason: "archive_read_new failed")
        }
        defer { archive_read_free(archive) }

        LibarchiveFormats.enable(archive, for: url, allowsCompressedTar: compressedTar)

        let status = url.path.withCString { cPath in
            archive_read_open_filename(archive, cPath, 16384)
        }
        if status != ARCHIVE_OK {
            let msg = errorMessage(archive)
            throw ArchiveAdapterError.archiveUnreadable(url, reason: msg.isEmpty ? "open failed" : msg)
        }

        var names: [String] = []
        var entry: OpaquePointer?
        var budget = TarWalkBudget(url: url, limits: limits)
        while true {
            let r = archive_read_next_header(archive, &entry)
            if r == ARCHIVE_EOF { break }
            // G64: tar を歩く量の上限を超えたら、ヘッダが読めなくなったのと同じに扱う。
            let overBudget = budget.exceeds(archive, header: r, entry: entry)
            if (r != ARCHIVE_OK && r != ARCHIVE_WARN) || overBudget {
                // G26: 破損等で途中打ち切り。**それまでに集めた分を返す**。
                // 1 件も集まっていなければ従来どおり throw する
                // （全く読めないファイルを「0 ページの本」として黙って開かせないため）。
                //
                // G27a task 8: ここは open は成功した**後**の header-read ループ内での破綻な
                // ので、`.archiveUnreadable`（open 自体が失敗＝未認識フォーマット／権限拒否等）
                // とは別の `.enumerationFailed` で throw する。libarchive がこの段で返す文言は
                // 破損パターンごとに全く異なり（"Damaged Zip archive" 等、固定の接頭辞を持たない）、
                // 文字列一致で安全に分類できないため、呼び出し元（QuickIntegrityScanner）は
                // この case を丸ごと固定の分類名に正規化する（生文字列は保持しても永続化しない）。
                if names.isEmpty {
                    let msg = overBudget ? TarWalkBudget.exceededReason : errorMessage(archive)
                    throw ArchiveAdapterError.enumerationFailed(url, reason: msg.isEmpty ? "read header failed" : msg)
                }
                return ArchiveListing(names: names, truncated: true)
            }
            guard let entry = entry else { archive_read_data_skip(archive); continue }
            guard let cName = archive_entry_pathname(entry) else { archive_read_data_skip(archive); continue }
            let name = String(cString: cName)
            archive_read_data_skip(archive)
            if name.hasSuffix("/") { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            if Self.imageExtensions.contains(ext) {
                names.append(name)
            }
        }
        return ArchiveListing(names: names, truncated: false)
    }

    /// Pass 2 — open the archive again and extract the entry whose pathname == targetName.
    private static func extractByName(from url: URL, targetName: String, limits: TarWalkLimits, compressedTar: Bool) throws -> Data {
        guard let archive = archive_read_new() else {
            throw ArchiveAdapterError.archiveUnreadable(url, reason: "archive_read_new failed")
        }
        defer { archive_read_free(archive) }

        LibarchiveFormats.enable(archive, for: url, allowsCompressedTar: compressedTar)

        let status = url.path.withCString { cPath in
            archive_read_open_filename(archive, cPath, 16384)
        }
        if status != ARCHIVE_OK {
            let msg = errorMessage(archive)
            throw ArchiveAdapterError.archiveUnreadable(url, reason: msg.isEmpty ? "open failed" : msg)
        }

        var entry: OpaquePointer?
        var budget = TarWalkBudget(url: url, limits: limits)
        while true {
            let r = archive_read_next_header(archive, &entry)
            if r == ARCHIVE_EOF { break }
            // G64: tar を歩く量の上限を超えたら、ヘッダが読めなくなったのと同じに扱う。
            let overBudget = budget.exceeds(archive, header: r, entry: entry)
            if (r != ARCHIVE_OK && r != ARCHIVE_WARN) || overBudget {
                let msg = overBudget ? TarWalkBudget.exceededReason : errorMessage(archive)
                throw ArchiveAdapterError.archiveUnreadable(url, reason: msg.isEmpty ? "read header failed" : msg)
            }
            guard let entry = entry else { archive_read_data_skip(archive); continue }
            guard let cName = archive_entry_pathname(entry) else { archive_read_data_skip(archive); continue }
            let name = String(cString: cName)
            guard name == targetName else { archive_read_data_skip(archive); continue }
            let size = Int(archive_entry_size(entry))
            if size <= 0 { archive_read_data_skip(archive); continue }
            // セキュリティ: archive_entry_size はアーカイブ自身の自己申告値（偽装可能）。
            // 上限超過分をそのまま Data(count:) で先行確保すると、実データが小さくても
            // 宣言サイズだけメモリを食い潰す decompression-bomb / OOM を許してしまう。
            // 確保前に skip して次のエントリへ（対象名と一致した唯一のエントリなので noImageEntry で返る）。
            if ArchiveEntrySizeLimit.shouldReject(size: size) {
                archive_read_data_skip(archive)
                continue
            }
            var buffer = Data(count: size)
            let bytesRead: Int = buffer.withUnsafeMutableBytes { rawBuf in
                guard let baseAddr = rawBuf.baseAddress else { return 0 }
                return archive_read_data(archive, baseAddr, size)
            }
            if bytesRead <= 0 { continue }
            return buffer.prefix(bytesRead)
        }
        throw ArchiveAdapterError.noImageEntry(url)
    }

    private static func count(from url: URL, limits: TarWalkLimits, compressedTar: Bool) throws -> ArchiveEntryCount {
        guard let archive = archive_read_new() else {
            throw ArchiveAdapterError.archiveUnreadable(url, reason: "archive_read_new failed")
        }
        defer { archive_read_free(archive) }

        LibarchiveFormats.enable(archive, for: url, allowsCompressedTar: compressedTar)

        let status = url.path.withCString { cPath in
            archive_read_open_filename(archive, cPath, 16384)
        }
        if status != ARCHIVE_OK {
            let msg = errorMessage(archive)
            throw ArchiveAdapterError.archiveUnreadable(url, reason: msg.isEmpty ? "open failed" : msg)
        }

        var count = 0
        var entry: OpaquePointer?
        var budget = TarWalkBudget(url: url, limits: limits)
        while true {
            let r = archive_read_next_header(archive, &entry)
            if r == ARCHIVE_EOF { break }
            // G64: tar を歩く量の上限を超えたら、ヘッダが読めなくなったのと同じに扱う。
            let overBudget = budget.exceeds(archive, header: r, entry: entry)
            if (r != ARCHIVE_OK && r != ARCHIVE_WARN) || overBudget {
                // G26: 途中打ち切り。数えられた分を truncated=true で返す（0 件なら throw）。
                if count == 0 {
                    let msg = overBudget ? TarWalkBudget.exceededReason : errorMessage(archive)
                    throw ArchiveAdapterError.archiveUnreadable(url, reason: msg.isEmpty ? "read header failed" : msg)
                }
                return ArchiveEntryCount(count: count, truncated: true)
            }
            guard let entry = entry,
                  let cName = archive_entry_pathname(entry) else {
                archive_read_data_skip(archive)
                continue
            }
            let name = String(cString: cName)
            if name.hasSuffix("/") {
                archive_read_data_skip(archive)
                continue
            }
            let ext = (name as NSString).pathExtension.lowercased()
            if Self.imageExtensions.contains(ext) {
                count += 1
            }
            archive_read_data_skip(archive)
        }
        return ArchiveEntryCount(count: count, truncated: false)
    }
}
