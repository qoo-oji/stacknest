// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore

/// G60: 参照ファイル（`.stacknestbook`）の中身（spec §5.4。版は §5.6 の交渉で決まり、今は 1 だけ）。
/// 対応した外部ビューアは `book` の API からページを取り、読み進めたページを書き戻す。
/// 形式の公開文書は `docs/book-reference-format.md`（日英）。項目を変えたらあちらも直す。
public struct BookReference: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let formatName = "stacknest-book-reference"
    /// G60 v3: StackNest が書ける参照ファイルの版。ビューアの宣言（`StackNestViewerSupport`）との共通の最大を書く。
    public static let writableVersions: [Int] = [1]
    public static let fileExtension = "stacknestbook"
    public static let typeIdentifier = "app.shelfsmith.stacknest.book-reference"

    public let format: String
    public let version: Int
    public let title: String
    /// 本の API の基点。ビューアは `{book}/manifest`・`{book}/pages/{n}`・`{book}/cover`・`{book}/progress` を使う。
    public let book: String
    /// その本専用の読み取りトークン（Bearer で渡す）。
    public let token: String
    public let expiresAt: Date
    /// 開いた時点の値（正は manifest）。
    public let pageCount: Int
    /// "rtl" / "ltr"。開いた時点の値（正は manifest）。
    public let direction: String
    /// 0 始まり。開いた時点の読書位置。
    public let startPage: Int

    /// - Parameter version: 書く版（`ReferenceViewer.formatVersion`＝宣言との共通の最大）。
    public init(version: Int, title: String, book: String, token: String, expiresAt: Date,
                pageCount: Int, direction: String, startPage: Int) {
        self.format = Self.formatName
        self.version = version
        self.title = title
        self.book = book
        self.token = token
        self.expiresAt = expiresAt
        self.pageCount = pageCount
        self.direction = direction
        self.startPage = startPage
    }

    /// トークンを出さない（ログやテスト失敗の表示に平文が漏れないように）。
    public var description: String {
        "BookReference(title: \(title), book: \(book), token: <redacted>, expiresAt: \(expiresAt), "
            + "pageCount: \(pageCount), direction: \(direction), startPage: \(startPage))"
    }

    public var debugDescription: String { description }

    /// `http://host:port/` と書庫・本から、本の API の基点を作る。
    public static func bookURL(serverBase: URL, libraryUUID: String, bookID: Int) -> String {
        serverBase.appendingPathComponent("api/v1/libraries/\(libraryUUID)/books/\(bookID)").absoluteString
    }

    /// サーバの manifest と同じ書き方（"rtl"/"ltr"）。
    public static func directionString(_ direction: PageDirection) -> String {
        direction == .leftToRight ? "ltr" : "rtl"
    }

    /// 開くページを 0…pageCount-1 に収める（0 ページの本は 0）。
    public static func clampedStartPage(_ page: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(max(0, page), pageCount - 1)
    }

    /// UTF-8 の JSON。日時は ISO 8601（UTC の Z）、URL のスラッシュはエスケープしない。
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// 知らない項目は読み飛ばす。
    public static func decode(_ data: Data) throws -> BookReference {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BookReference.self, from: data)
    }
}

/// G60: 参照ファイルの置き場と書き出し（spec §5.4）。
///
/// 置き場は `<Application Support>/StackNest/ViewerHandoff/<発行先>/<書庫>/<本>/<題名>.stacknestbook`。
/// 発行先は `local`（127.0.0.1 の口）か `remote-<serverID>`。**トークンの平文が入る**ので、
/// ファイルは 600、ディレクトリは 700 にする。開くたびに本の部屋を空にして書き直す（改題で古い名前を残さない）。
public struct BookReferenceStore: Sendable {
    public enum Origin: Sendable, Equatable {
        case local
        case remote(serverID: UUID)

        var directoryName: String {
            switch self {
            case .local: return "local"
            case .remote(let serverID): return "remote-\(serverID.uuidString)"
            }
        }
    }

    public enum WriteError: Error, Equatable {
        /// 書庫の UUID がパスの 1 階層として安全でない（サーバから来た値なので確かめる）。
        case invalidLibraryUUID
    }

    public let root: URL
    private var fm: FileManager { .default }

    public init(baseDirectory: URL? = nil) {
        let base = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StackNest", isDirectory: true)
        self.root = base.appendingPathComponent("ViewerHandoff", isDirectory: true)
    }

    /// 書き出して、そのファイルの URL を返す。
    @discardableResult
    public func write(_ reference: BookReference, origin: Origin, libraryUUID: String, bookID: Int) throws -> URL {
        guard Self.isSafeComponent(libraryUUID) else { throw WriteError.invalidLibraryUUID }
        let ownerOnlyDirectory: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        // 根は先に 700 で作る。シンボリックリンクなら（リンク先には触れず）リンクごと消して作り直す。
        try removeIfSymlink(root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: ownerOnlyDirectory)
        try fm.setAttributes(ownerOnlyDirectory, ofItemAtPath: root.path)
        let originDirectory = root.appendingPathComponent(origin.directoryName, isDirectory: true)
        let libraryDirectory = originDirectory.appendingPathComponent(libraryUUID, isDirectory: true)
        let room = libraryDirectory.appendingPathComponent(String(bookID), isDirectory: true)
        // 各段を実ディレクトリの 700 にする（既存の緩い権限も締め直す。リンクはリンク先を触らず作り直す）。
        for directory in [originDirectory, libraryDirectory, room] {
            try removeIfSymlink(directory)
            if !fm.fileExists(atPath: directory.path) {
                try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: ownerOnlyDirectory)
            }
            try fm.setAttributes(ownerOnlyDirectory, ofItemAtPath: directory.path)
        }
        for name in (try? fm.contentsOfDirectory(atPath: room.path)) ?? [] {
            try? fm.removeItem(at: room.appendingPathComponent(name))
        }
        let name = OfflineExternalLink.safeFileName(title: reference.title, fallbackID: bookID,
                                                    fileExtension: BookReference.fileExtension)
        let dest = room.appendingPathComponent(name)
        // トークンの平文が入るので、最初から 600 で作った一時ファイルに書いて rename する（644 の瞬間を作らない）。
        let temp = room.appendingPathComponent(".tmp-\(UUID().uuidString)")
        do {
            try Self.writeOwnerOnly(reference.encoded(), to: temp)
            if rename(temp.path, dest.path) != 0 {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        return dest
    }

    /// リンクそのものを調べ（リンク先は辿らない）、シンボリックリンクならリンクだけを消す。
    private func removeIfSymlink(_ url: URL) throws {
        let type = (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        if type == .typeSymbolicLink { try fm.removeItem(at: url) }
    }

    /// 600 で新規作成（O_EXCL・O_NOFOLLOW）して書き切る。
    private static func writeOwnerOnly(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        var offset = 0
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw CocoaError(.fileWriteUnknown) }
                offset += n
            }
        }
    }

    /// 期限切れ・読めない参照ファイルを消し、空になったディレクトリを畳む。起動時に呼ぶ。消した件数を返す。
    @discardableResult
    public func pruneExpired(now: Date = Date()) -> Int {
        guard fm.fileExists(atPath: root.path) else { return 0 }
        var doomed: [URL] = []
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == BookReference.fileExtension {
                let reference = (try? Data(contentsOf: url)).flatMap { try? BookReference.decode($0) }
                if let reference, reference.expiresAt > now { continue }
                doomed.append(url)
            }
        }
        // 書き込み中の異常終了で残った一時ファイル（平文のトークンが入る）。通常ファイルだけ・書き込み中と
        // 競合しないよう 60 秒より古いものだけを消す。リンクは辿らない（attributesOfItem はリンク自体を見る）。
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.lastPathComponent.hasPrefix(".tmp-") {
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      attrs[.type] as? FileAttributeType == .typeRegular,
                      let modified = attrs[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) > 60 else { continue }
                doomed.append(url)
            }
        }
        for url in doomed { try? fm.removeItem(at: url) }
        removeEmptyDirectories(under: root)
        return doomed.count
    }

    private func removeEmptyDirectories(under directory: URL) {
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let child = directory.appendingPathComponent(name, isDirectory: true)
            // リンクは辿らない（根の外の空ディレクトリを消さない）。
            let type = (try? fm.attributesOfItem(atPath: child.path))?[.type] as? FileAttributeType
            guard type == .typeDirectory else { continue }
            removeEmptyDirectories(under: child)
            if ((try? fm.contentsOfDirectory(atPath: child.path)) ?? []).isEmpty {
                try? fm.removeItem(at: child)
            }
        }
    }

    /// パスの 1 階層として安全か（ASCII の英数字・`-`・`_` だけ、1〜128 文字）。
    static func isSafeComponent(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 128 else { return false }
        return s.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
        }
    }
}
