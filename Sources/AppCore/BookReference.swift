// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore
import StackNestViewerKitCore

/// G60 → G63 段 4: 参照ファイル（`.stacknestbook`）の中身の型は、StackNestViewerKit の `StackNestBookReference`
/// （作る側の StackNest と読む側のビューアが共有する唯一の定義・spec §5.4）。ここに残るのは StackNest に固有の決まり。
/// 形式の公開文書は StackNestViewerKit のリポジトリの `Documentation/BookReferenceFormat.md`（日英）。
public enum BookReferences {
    /// G60 v3: StackNest が書ける参照ファイルの版。ビューアの宣言（`StackNestViewerSupport`）との共通の最大を書く。
    /// 部品が読める版（`StackNestFormat.supportedVersions`）に含まれることを試験で確かめる。
    public static let writableVersions: [Int] = [1]

    /// `http://host:port/` と書庫・本から、本の API の基点を作る（`…/api/v1/libraries/<lib>/books/<id>`）。
    public static func bookURL(serverBase: URL, libraryUUID: String, bookID: Int) -> URL {
        serverBase.appendingPathComponent("api/v1/libraries/\(libraryUUID)/books/\(bookID)")
    }

    /// G60 v3（spec §5.8）: リモートの本を中継する 127.0.0.1 の口の基点（`…/api/v1/relay/<relayID>`）。
    /// ビューアから見た形（`manifest`・`pages/{n}`・`cover`・`progress`）はローカルの本と同じ。
    public static func relayURL(localBase: URL, relayID: String) -> URL {
        localBase.appendingPathComponent("api/v1/relay/\(relayID)")
    }

    /// 書庫の読む向きを、参照ファイルの読む向きへ写す（サーバの manifest と同じ "rtl"／"ltr"）。
    public static func direction(_ direction: PageDirection) -> StackNestReadingDirection {
        direction == .leftToRight ? .leftToRight : .rightToLeft
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

    /// Codex P2（5 回目）: 参照ファイルの書き込みと起動時の掃除を、プロセスの中で 1 本の列に並べる。掃除は別の Task・
    /// 別のインスタンスで走るので、消す相手を決めてから消すまでのあいだに同じ本の渡しが同じ名前で書き直すと、書いた
    /// ばかりのファイルを消していた（空の部屋を畳むのも同じ）。インスタンスをまたぐので型の鍵にする。
    private static let ioLock = NSLock()

    /// テスト用: この店の掃除が消す相手を決めた後・消す前に呼ぶ（鍵を持ったまま）。インスタンスごとなので、
    /// 並行に走るほかの掃除からは呼ばれない（Codex P2・6 回目）。
    let pruneHookBeforeDeletes: (@Sendable () -> Void)?

    public init(baseDirectory: URL? = nil) {
        self.init(baseDirectory: baseDirectory, pruneHookBeforeDeletes: nil)
    }

    /// テスト用: 掃除の途中に差し込む閉包を持たせる。
    init(baseDirectory: URL?, pruneHookBeforeDeletes: (@Sendable () -> Void)?) {
        self.pruneHookBeforeDeletes = pruneHookBeforeDeletes
        let base = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StackNest", isDirectory: true)
        self.root = base.appendingPathComponent("ViewerHandoff", isDirectory: true)
    }

    /// 書き出して、そのファイルの URL を返す。
    @discardableResult
    public func write(_ reference: StackNestBookReference, origin: Origin, libraryUUID: String, bookID: Int) throws -> URL {
        guard Self.isSafeComponent(libraryUUID) else { throw WriteError.invalidLibraryUUID }
        return try Self.ioLock.withLock {
            try writeLocked(reference, origin: origin, libraryUUID: libraryUUID, bookID: bookID)
        }
    }

    private func writeLocked(_ reference: StackNestBookReference, origin: Origin, libraryUUID: String, bookID: Int) throws -> URL {
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
                                                    fileExtension: StackNestFormat.fileExtension)
        let dest = room.appendingPathComponent(name)
        // トークンの平文が入るので、最初から 600 で作った一時ファイルに書いて rename する（644 の瞬間を作らない）。
        let temp = room.appendingPathComponent(".tmp-\(UUID().uuidString)")
        do {
            try Self.writeOwnerOnly(reference.encodedJSON(), to: temp)
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
        Self.ioLock.withLock { pruneExpiredLocked(now: now) }
    }

    private func pruneExpiredLocked(now: Date) -> Int {
        guard fm.fileExists(atPath: root.path) else { return 0 }
        var doomed: [URL] = []
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            // 拡張子は大文字小文字を区別して比べる（StackNest が書く名前は小文字だけ。掃除の対象を広げない）。
            for case let url as URL in walker where url.pathExtension == StackNestFormat.fileExtension {
                if let reference = try? StackNestBookReference.load(contentsOf: url), !reference.isExpired(at: now) {
                    continue
                }
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
        pruneHookBeforeDeletes?()
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
