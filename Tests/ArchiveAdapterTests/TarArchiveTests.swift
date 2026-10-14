// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter
import Carchive

/// G64: libarchive で tar（`.cbt`・`.tar`・フィルタ越しの `.tgz`）を読む（spec §6.3）。
/// tar は `/usr/bin/tar`（bsdtar）でその場で作る（蔵書の実物はリポジトリに入れない）。
@Suite("G64: tar を読む")
struct TarArchiveTests {
    /// 一時ディレクトリに PNG 3 枚とテキスト 1 つを置き、tar を作る。中の並びは page01・page10・page02・notes.txt
    /// （自然順の並べ替えを確かめるため、アーカイブの中の順は自然順と違えてある）。
    static func makeTar(named fileName: String, gzip: Bool = false, flag: String? = nil) throws -> (url: URL, dir: URL, pages: [String: Data]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-tar-\(UUID().uuidString)")
        let src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let pages: [String: Data] = [
            "page01.png": try LibarchiveCoverExtractorTests.make1x1PNG(r: 10, g: 20, b: 30),
            "page02.png": try LibarchiveCoverExtractorTests.make1x1PNG(r: 40, g: 50, b: 60),
            "page10.png": try LibarchiveCoverExtractorTests.make1x1PNG(r: 70, g: 80, b: 90),
        ]
        for (name, data) in pages { try data.write(to: src.appendingPathComponent(name)) }
        try Data("not a page".utf8).write(to: src.appendingPathComponent("notes.txt"))
        let url = dir.appendingPathComponent(fileName)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // COPYFILE_DISABLE: macOS の tar が拡張属性を `._` のエントリとして入れないようにする。
        process.environment = ["COPYFILE_DISABLE": "1"]
        process.arguments = [flag ?? (gzip ? "-czf" : "-cf"), url.path, "-C", src.path,
                             "page01.png", "page10.png", "page02.png", "notes.txt"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "TarHelper", code: Int(process.terminationStatus))
        }
        return (url, dir, pages)
    }

    @Test("tar（.cbt・.tar・.tgz）の画像を自然順に並べ、数え、取り出せる", arguments: ["book.cbt", "book.tar", "book.tgz"])
    func listsCountsAndExtracts(fileName: String) async throws {
        let (url, dir, pages) = try Self.makeTar(named: fileName, gzip: fileName.hasSuffix(".tgz"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let extractor = LibarchiveCoverExtractor(allowsCompressedTar: fileName.hasSuffix(".tgz"))   // .tgz だけ足した拡張子として読む（本番と同じ）

        let listing = try await extractor.listImageEntries(in: url)
        #expect(listing.names == ["page01.png", "page02.png", "page10.png"])
        #expect(listing.truncated == false)
        let count = try await extractor.countImageEntries(in: url)
        #expect(count.count == 3 && count.truncated == false)
        #expect(try await extractor.extractCoverImage(from: url) == pages["page01.png"])
        #expect(try await extractor.extractCoverImage(from: url, preferredName: "page10.png") == pages["page10.png"])
        #expect(try await extractor.imageData(in: url, entryName: "page02.png") == pages["page02.png"])
        #expect(try await extractor.extractFirstPDFData(in: url) == nil)
    }

    @Test("順方向の取り出し（内蔵ビューアのページ）で tar を読める")
    func sequentialExtractorReadsTar() async throws {
        let (url, dir, pages) = try Self.makeTar(named: "book.cbt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let seq = SequentialArchiveExtractor(url: url, imageNames: Set(pages.keys))
        #expect(try await seq.data(forName: "page02.png") == pages["page02.png"])
        #expect(try await seq.data(forName: "page01.png") == pages["page01.png"])
        #expect(try await seq.data(forName: "page10.png") == pages["page10.png"])
    }

    @Test("詳細チェックは tar を最後まで読む（データの CRC は無いので、読めれば OK）", arguments: ["book.cbt", "book.tgz"])
    func verifierReadsTarToTheEnd(fileName: String) throws {
        let (url, dir, _) = try Self.makeTar(named: fileName, gzip: fileName.hasSuffix(".tgz"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try ArchiveIntegrityVerifier.verifySync(url: url, allowsCompressedTar: fileName.hasSuffix(".tgz"))
        #expect(result == ArchiveVerifyResult(entryCount: 4, imageCount: 3, badEntries: [], truncated: false))
    }

    @Test("途中で切れた tar は打ち切りとして出る（読めた分だけ返す）")
    func truncatedTarIsTruncated() async throws {
        let (url, dir, _) = try Self.makeTar(named: "book.cbt")
        defer { try? FileManager.default.removeItem(at: dir) }
        // 1 つ目のエントリ（ヘッダ 512 バイト＋データ 512 バイト）の後、2 つ目のヘッダの途中で切る。
        let full = try Data(contentsOf: url)
        let cut = dir.appendingPathComponent("cut.cbt")
        try full.prefix(1100).write(to: cut)

        let listing = try await LibarchiveCoverExtractor().listImageEntries(in: cut)
        #expect(listing.names == ["page01.png"])
        #expect(listing.truncated == true)
        let count = try await LibarchiveCoverExtractor().countImageEntries(in: cut)
        #expect(count.count == 1 && count.truncated == true)
        let verified = try ArchiveIntegrityVerifier.verifySync(url: cut)
        #expect(verified.truncated == true)
        #expect(verified.entryCount == 1)
    }

    /// `format_all`（`empty`）を使っていないことの回帰。0 バイトの zip も cbt も今どおり「unrecognized archive format」。
    @Test("0 バイトの zip と cbt は開けない（Unrecognized archive format）", arguments: ["empty0.zip", "empty0.cbt"])
    func zeroByteFilesStayUnrecognized(fileName: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-zero-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(fileName)
        try Data().write(to: url)
        try await Self.expectUnrecognized(url)
    }

    /// 0 で埋まった（512 バイト以上の）zip 系は、tar を有効にすると「空の tar」として開けてしまう。
    /// zip 系では tar を有効にしないので、今どおり開けない（＝破損チェックで「破損」のまま）。
    @Test("0 で埋まった zip 系は開けないまま", arguments: ["zeros.zip", "zeros.cbz", "zeros.rar", "zeros.7z", "zeros.epub"])
    func zeroFilledZipFamilyStaysUnrecognized(fileName: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-zeros-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(fileName)
        try Data(count: 4096).write(to: url)
        try await Self.expectUnrecognized(url)
    }

    /// 対照: 標準の tar の 0 埋めは、tar の約束どおり「空の tar」として開ける（画像 0 枚）。
    /// libarchive・GNU tar と同じ振る舞いで、破損チェックでは「空」になる。
    @Test("0 で埋まった cbt は空の tar として開ける")
    func zeroFilledCBTIsAnEmptyTar() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-zeros-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("zeros.cbt")
        try Data(count: 4096).write(to: url)
        let listing = try await LibarchiveCoverExtractor().listImageEntries(in: url)
        #expect(listing.names.isEmpty && listing.truncated == false)
    }

    @Test("でたらめなバイトの cbt・zip は開けない", arguments: ["noise.cbt", "noise.zip"])
    func noiseStaysUnrecognized(fileName: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-noise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(fileName)
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: url)
        try await Self.expectUnrecognized(url)
    }

    @Test("tar を有効にするのは zip 系以外")
    func readsTarOnlyOutsideTheZipFamily() {
        for ext in ["zip", "cbz", "rar", "cbr", "7z", "cb7", "epub", "ZIP"] {
            #expect(!LibarchiveFormats.readsTar(URL(fileURLWithPath: "/tmp/a.\(ext)")), "\(ext)")
        }
        for ext in ["cbt", "tar", "TAR", "tgz", "gz", "djvu", ""] {
            #expect(LibarchiveFormats.readsTar(URL(fileURLWithPath: "/tmp/a.\(ext)")), "\(ext)")
        }
    }

    /// 一覧（簡易チェックの道）と詳細チェックのどちらでも、開く段で「Unrecognized archive format」になる。
    static func expectUnrecognized(_ url: URL, allowsCompressedTar: Bool = false) async throws {
        await #expect {
            _ = try await LibarchiveCoverExtractor(allowsCompressedTar: allowsCompressedTar).listImageEntries(in: url)
        } throws: { error in
            guard case .archiveUnreadable(_, let reason) = error as? ArchiveAdapterError else { return false }
            return reason.contains("Unrecognized archive format")
        }
        #expect {
            _ = try ArchiveIntegrityVerifier.verifySync(url: url, allowsCompressedTar: allowsCompressedTar)
        } throws: { error in
            guard case .archiveUnreadable(_, let reason) = error as? ArchiveAdapterError else { return false }
            return reason.contains("Unrecognized archive format")
        }
    }

    // MARK: - G64: フィルタ（外側の圧縮）

    @Test("tar を読む開き方は、足したアーカイブ（allowsCompressedTar）のときだけ gzip・zip 系は自前で解けるもの全部")
    func filtersPerOpening() {
        for name in ["a.cbt", "a.tar", "a.tgz", "a.djvu", "a.xyz"] {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            #expect(LibarchiveFormats.filters(for: url) == [], "\(name)")
            #expect(LibarchiveFormats.filters(for: url, allowsCompressedTar: false) == [], "\(name)")
            #expect(LibarchiveFormats.filters(for: url, allowsCompressedTar: true) == [.gzip], "\(name)")
        }
        for name in ["a.zip", "a.cbz", "a.rar", "a.7z", "a.epub"] {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            #expect(LibarchiveFormats.filters(for: url) == LibarchiveFormats.builtInFilters, "\(name)")
            #expect(LibarchiveFormats.filters(for: url, allowsCompressedTar: true) == LibarchiveFormats.builtInFilters, "\(name)")
        }
    }

    /// G64 最終レビュー I1: gzip で包んだ tar は `allowsCompressedTar` のときだけ読む（既定は読まない）。
    @Test("gzip の tar は allowsCompressedTar のときだけ読む（一覧・数える・取り出す・順方向・詳細チェック）")
    func gzipTarNeedsTheFlag() async throws {
        let (url, dir, pages) = try Self.makeTar(named: "book.cbt", gzip: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 既定（false）: 標準の .cbt と同じ名前でも開けない。
        try await Self.expectUnrecognized(url)
        await #expect(throws: ArchiveAdapterError.self) { _ = try await LibarchiveCoverExtractor().countImageEntries(in: url) }
        await #expect(throws: ArchiveAdapterError.self) { _ = try await LibarchiveCoverExtractor().extractCoverImage(from: url) }
        await #expect(throws: ArchiveAdapterError.self) {
            _ = try await SequentialArchiveExtractor(url: url, imageNames: Set(pages.keys)).data(forName: "page01.png")
        }
        // true: 読める。
        let on = LibarchiveCoverExtractor(allowsCompressedTar: true)
        #expect(try await on.listImageEntries(in: url).names.count == 3)
        #expect(try await on.extractCoverImage(from: url) == pages["page01.png"])
        let seq = SequentialArchiveExtractor(url: url, imageNames: Set(pages.keys), allowsCompressedTar: true)
        #expect(try await seq.data(forName: "page02.png") == pages["page02.png"])
        #expect(try ArchiveIntegrityVerifier.verifySync(url: url, allowsCompressedTar: true).imageCount == 3)
        // 素の tar は、どちらでも読める。
        let (plain, dir2, _) = try Self.makeTar(named: "plain.cbt")
        defer { try? FileManager.default.removeItem(at: dir2) }
        #expect(try await LibarchiveCoverExtractor().listImageEntries(in: plain).names.count == 3)
        #expect(try ArchiveIntegrityVerifier.verifySync(url: plain).imageCount == 3)
    }

    /// bzip2・xz は 1 回の呼び出しの中で小さなファイルを巨大に膨らませられるので、tar を読む開き方では登録しない。
    @Test("bzip2・xz で包んだ tar は開けない", arguments: [("book.tbz", "-cjf"), ("book.txz", "-cJf"), ("book2.cbt", "-cjf")])
    func bzip2AndXZAreNotReadForTar(fileName: String, flag: String) async throws {
        let (url, dir, _) = try Self.makeTar(named: fileName, flag: flag)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await Self.expectUnrecognized(url, allowsCompressedTar: true)   // gzip を許しても bzip2・xz は開けない
    }

    @Test("登録するフィルタは自前で解けるものだけ（外部のプログラムを起動しない）")
    func registersOnlyBuiltInFilters() throws {
        let filters = LibarchiveFormats.builtInFilters
        #expect(filters.contains(.gzip) && filters.contains(.bzip2) && filters.contains(.xz))
        for filter in filters {
            let probe = try #require(archive_read_new())
            defer { archive_read_free(probe) }
            #expect(filter.register(probe) == ARCHIVE_OK, "\(filter)")
        }
    }

    /// zstd の印で始まるでたらめなバイト。`filter_all` だと（この macOS の libarchive は zstd を自前で解けないので）
    /// PATH 上の `zstd` を起動し「Child process exited …」になる。自前のフィルタだけなら開けない形式のまま。
    @Test("zstd の印のファイルで外部のプログラムを起動しない")
    func doesNotSpawnZstd() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-zstd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("junk.cbt")
        try (Data([0x28, 0xB5, 0x2F, 0xFD]) + Data((0..<200).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })).write(to: url)
        do {
            _ = try await LibarchiveCoverExtractor().listImageEntries(in: url)
            Issue.record("でたらめなバイトが開けた")
        } catch ArchiveAdapterError.archiveUnreadable(_, let reason) {
            #expect(!reason.contains("Child process"), "外部のプログラムを起動した: \(reason)")
            if !LibarchiveFormats.builtInFilters.contains(.zstd) {
                #expect(reason.contains("Unrecognized archive format"))
            }
        }
    }

    // MARK: - G64: tar を歩く仕事の上限

    @Test("既定の上限は エントリ 10 万・256 MiB ＋ ファイルの 64 倍（頭打ち 64 GiB）")
    func standardLimits() {
        let standard = TarWalkLimits.standard
        #expect(standard == TarWalkLimits(maxEntries: 100_000, baseBytes: 256 << 20, bytesPerFileByte: 64,
                                          maxScaledBytes: 64 << 30))
        #expect(standard.limitBytes(fileSize: 1 << 20) == (256 << 20) + (64 << 20))
        // sparse ファイルなどで論理サイズが膨らんでも、足す量は 64 GiB で頭打ち（あふれもしない）。
        #expect(standard.limitBytes(fileSize: 1 << 40) == (256 << 20) + (64 << 30))
        #expect(standard.limitBytes(fileSize: .max) == (256 << 20) + (64 << 30))
    }

    /// ustar のヘッダ 1 つ（512 バイト・チェックサム入り）。`gnu` なら古い GNU の印（`ustar  \0`）で、`edit` で欄を足せる。
    static func ustarHeader(name: String, size: UInt64, type: Character = "0", gnu: Bool = false,
                            edit: (inout [UInt8]) -> Void = { _ in }) -> Data {
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, at offset: Int) { for (i, b) in s.utf8.enumerated() { h[offset + i] = b } }
        put(name, at: 0)
        put("0000644", at: 100); put("0000000", at: 108); put("0000000", at: 116)
        put(String(size, radix: 8).leftPadded(to: 11), at: 124)
        put("00000000000", at: 136)
        put("        ", at: 148)            // チェックサムの計算中は空白
        h[156] = type.asciiValue!
        if gnu { put("ustar  ", at: 257) } else { put("ustar", at: 257); put("00", at: 263) }
        edit(&h)
        let sum = h.reduce(0) { $0 + Int($1) }
        put(String(sum, radix: 8).leftPadded(to: 6), at: 148)
        h[154] = 0; h[155] = UInt8(ascii: " ")
        return Data(h)
    }

    /// 2 バイトの `real.png` と終わりの印（0 のブロック 2 つ）。
    static let realEntryAndEnd = ustarHeader(name: "real.png", size: 2) + Data("zz".utf8) + Data(count: 510) + Data(count: 1024)

    /// `data` を `/usr/bin/gzip`・`/usr/bin/bzip2` で包んで `url` に書く。
    static func compress(_ data: Data, with tool: String, to url: URL) throws {
        let raw = url.appendingPathExtension("raw")
        try data.write(to: raw)
        defer { try? FileManager.default.removeItem(at: raw) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/\(tool)")
        process.arguments = ["-c"]
        process.standardInput = try FileHandle(forReadingFrom: raw)
        process.standardOutput = try FileHandle(forWritingTo: url)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "compress", code: Int(process.terminationStatus)) }
    }

    /// 中身より大きいサイズ（8 GiB − 1）を申告するエントリは、既定の上限で**読み飛ばす前に**断る（理由が上限のもの）。
    /// 読めたエントリが無いので、一覧・数える・詳細チェックは「開けない」側になる。
    @Test("既定の上限で、巨大なサイズを申告する tar を読み飛ばす前に断る")
    func oversizedDeclarationIsRejectedQuickly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-bomb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bomb.cbt")
        try (Self.ustarHeader(name: "big.png", size: 0o77777777777) + Data(count: 1024)).write(to: url)

        await #expect {
            _ = try await LibarchiveCoverExtractor().listImageEntries(in: url)
        } throws: { error in
            guard case .enumerationFailed(_, let reason) = error as? ArchiveAdapterError else { return false }
            return reason == TarWalkBudget.exceededReason
        }
        await #expect(throws: ArchiveAdapterError.self) {
            _ = try await LibarchiveCoverExtractor().countImageEntries(in: url)
        }
        #expect {
            _ = try ArchiveIntegrityVerifier.verifySync(url: url)
        } throws: { error in
            guard case .enumerationFailed(_, let reason) = error as? ArchiveAdapterError else { return false }
            return reason == TarWalkBudget.exceededReason
        }
    }

    @Test("エントリの数の上限を超えたら、そこで打ち切り（読めた分を返す）")
    func entryLimitTruncates() async throws {
        let (url, dir, pages) = try Self.makeTar(named: "book.tgz", gzip: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let limits = TarWalkLimits(maxEntries: 2, baseBytes: 1 << 30, bytesPerFileByte: 0, maxScaledBytes: 0)
        let extractor = LibarchiveCoverExtractor(walkLimits: limits, allowsCompressedTar: true)

        let listing = try await extractor.listImageEntries(in: url)
        #expect(listing.names == ["page01.png", "page10.png"])     // 3 つ目（page02）で止まる
        #expect(listing.truncated == true)
        let count = try await extractor.countImageEntries(in: url)
        #expect(count.count == 2 && count.truncated == true)
        let verified = try ArchiveIntegrityVerifier.verifySync(url: url, walkLimits: limits, allowsCompressedTar: true)
        #expect(verified.truncated == true && verified.entryCount == 2)
        // 上限の手前のエントリは取り出せ、先のエントリは「開けない」になる。
        #expect(try await extractor.imageData(in: url, entryName: "page10.png") == pages["page10.png"])
        await #expect(throws: ArchiveAdapterError.self) {
            _ = try await extractor.imageData(in: url, entryName: "page02.png")
        }
        let seq = SequentialArchiveExtractor(url: url, imageNames: Set(pages.keys), walkLimits: limits,
                                           allowsCompressedTar: true)
        #expect(try await seq.data(forName: "page01.png") == pages["page01.png"])
        await #expect(throws: ArchiveAdapterError.self) {
            _ = try await seq.data(forName: "page02.png")
        }
    }

    @Test("申告サイズの合計の上限を超えたら、そこで打ち切り")
    func byteLimitTruncates() async throws {
        let (url, dir, pages) = try Self.makeTar(named: "book.cbt")
        defer { try? FileManager.default.removeItem(at: dir) }
        // 1 つ目のエントリ（ヘッダ 512 バイト＋中身）までは歩ける（ファイルの大きさは数えない）。
        let first = 512 + Int64(try #require(pages["page01.png"]).count)
        let limits = TarWalkLimits(maxEntries: 100, baseBytes: first, bytesPerFileByte: 0, maxScaledBytes: 0)
        let listing = try await LibarchiveCoverExtractor(walkLimits: limits).listImageEntries(in: url)
        #expect(listing.names == ["page01.png"] && listing.truncated == true)
        // 1 バイトも歩けなければ、読めた分が無いので開けない。
        let none = TarWalkLimits(maxEntries: 100, baseBytes: 0, bytesPerFileByte: 0, maxScaledBytes: 0)
        await #expect(throws: ArchiveAdapterError.self) {
            _ = try await LibarchiveCoverExtractor(walkLimits: none).listImageEntries(in: url)
        }
        // ファイルの大きさの倍率で広がる（このファイルなら 1 倍で全部歩ける）。
        let scaled = TarWalkLimits(maxEntries: 100, baseBytes: 0, bytesPerFileByte: 1, maxScaledBytes: 1 << 30)
        #expect(try await LibarchiveCoverExtractor(walkLimits: scaled).listImageEntries(in: url).truncated == false)
    }

    /// ヘッダの手前で libarchive が歩いた量（GNU の長い名前の特別なヘッダ 4 つ＝4 MiB）も数える。申告サイズは 2 バイトでも断る。
    @Test("特別なヘッダで歩いた量も数える（gzip で包んだ長い名前のヘッダ）")
    func specialHeadersAreCounted() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-special-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let nameBytes = 1 << 20
        var tar = Data()
        for _ in 0..<4 {
            tar += Self.ustarHeader(name: "././@LongLink", size: UInt64(nameBytes), type: "L", gnu: true)
            tar += Data(repeating: UInt8(ascii: "a"), count: nameBytes)
        }
        tar += Self.realEntryAndEnd
        let url = dir.appendingPathComponent("long.cbt")
        try Self.compress(tar, with: "gzip", to: url)

        let small = TarWalkLimits(maxEntries: 100, baseBytes: 1 << 20, bytesPerFileByte: 0, maxScaledBytes: 0)
        await #expect {
            _ = try await LibarchiveCoverExtractor(walkLimits: small, allowsCompressedTar: true).listImageEntries(in: url)
        } throws: { error in
            guard case .enumerationFailed(_, let reason) = error as? ArchiveAdapterError else { return false }
            return reason == TarWalkBudget.exceededReason
        }
        // 既定の上限なら読める（名前が長い 1 エントリで、画像ではない）。
        let listing = try await LibarchiveCoverExtractor(allowsCompressedTar: true).listImageEntries(in: url)
        #expect(listing.names.isEmpty && listing.truncated == false)
    }

    /// 古い GNU の sparse の拡張ブロックの連なりは、ヘッダを 1 つ読む呼び出しの中で全部歩かれる（libarchive に上限が無い）。
    /// 歩いた量は次のヘッダで数えて断る。bzip2 なら 1.4 KB で 1 GiB を歩かせられるので、tar を読む開き方では bzip2 を登録しない。
    @Test("sparse の拡張ブロックの連なりも数える・bzip2 では開かない")
    func sparseChainIsCountedAndBzip2IsNotRead() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-sparse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocks = 8 * 2048   // 8 MiB の拡張ブロック
        var tar = Self.ustarHeader(name: "sparse.png", size: 0, type: "S", gnu: true) { h in
            for (i, b) in "00000000000".utf8.enumerated() { h[386 + i] = b }   // sparse[0].offset
            for (i, b) in "00000000001".utf8.enumerated() { h[398 + i] = b }   // sparse[0].numbytes
            h[482] = 1                                                          // isextended
            for (i, b) in "00000000000".utf8.enumerated() { h[483 + i] = b }   // realsize
        }
        var extended = [UInt8](repeating: 0, count: 512)
        extended[504] = 1
        let extendedBlock = Data(extended)
        for _ in 0..<(blocks - 1) { tar += extendedBlock }
        tar += Data(count: 512)          // 最後の拡張ブロック（isextended = 0）
        tar += Self.realEntryAndEnd

        let gz = dir.appendingPathComponent("sparse.cbt")
        try Self.compress(tar, with: "gzip", to: gz)
        let small = TarWalkLimits(maxEntries: 100, baseBytes: 1 << 20, bytesPerFileByte: 0, maxScaledBytes: 0)
        await #expect {
            _ = try await LibarchiveCoverExtractor(walkLimits: small, allowsCompressedTar: true).listImageEntries(in: gz)
        } throws: { error in
            guard case .enumerationFailed(_, let reason) = error as? ArchiveAdapterError else { return false }
            return reason == TarWalkBudget.exceededReason
        }

        let bz = dir.appendingPathComponent("sparse-bz.cbt")
        try Self.compress(tar, with: "bzip2", to: bz)
        try await Self.expectUnrecognized(bz, allowsCompressedTar: true)
    }

    /// zip・rar・7z は数えない（今のまま）。エントリ 1 つまでの上限でも zip の 3 枚は全部読める。
    @Test("zip は上限の対象外")
    func zipIsNotCounted() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g64-zipnc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("three.cbz")
        let png = try LibarchiveCoverExtractorTests.make1x1PNG(r: 1, g: 2, b: 3)
        try DamagedArchiveTests.makeStoredZip([("1.png", png), ("2.png", png), ("3.png", png)]).write(to: url)
        let limits = TarWalkLimits(maxEntries: 1, baseBytes: 0, bytesPerFileByte: 0, maxScaledBytes: 0)
        let listing = try await LibarchiveCoverExtractor(walkLimits: limits).listImageEntries(in: url)
        #expect(listing.names.count == 3 && listing.truncated == false)
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
