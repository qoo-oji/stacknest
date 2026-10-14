// SPDX-License-Identifier: MIT
import Foundation
import Carchive

/// G64: libarchive で読む形式とフィルタ（外側の圧縮）の有効化。**ここ 1 か所だけ**（以前は同じ 5 行が 6 か所にあった）。
/// 呼び出し元は `LibarchiveCoverExtractor`（一覧・PDF の一覧・名前で取り出す・数える）・`SequentialArchiveExtractor`・
/// `ArchiveIntegrityVerifier` の 6 か所で、どれも `TarWalkBudget` で tar を歩く量を縛る。
///
/// 形式は zip・rar・rar5・7zip と、G64 で足した tar（ustar・pax・GNU tar）。`format_all` は使わない（中の `empty` が
/// 0 バイトのファイルを「空のアーカイブ」として開き、0 バイトの zip の破損の判定が変わるため）。
///
/// **zip 系の拡張子では tar を有効にしない。** tar の読み手は「512 バイトが全部 0 のブロック」をアーカイブの終わりとして
/// 受け付けるので、有効にすると 0 で埋まった（512 バイト以上の）壊れた `.zip` が「空の tar」として開け、破損チェックの
/// 判定が「破損」から「空」に変わってしまう（2026-10-09 に実測）。標準の zip 系の振る舞いを変えないため、tar を読むのは
/// 標準の `cbt`・`tar`、足した拡張子、未知の拡張子（`.tgz` など）だけにする。
///
/// **フィルタは libarchive が自前で解けるものだけ**（作者の確認事項 A）。`archive_read_support_filter_all` は、自前の
/// 解き手が無い形式（この macOS の libarchive 3.7.4 では zstd・lz4・lzop・lrzip・grzip）を**外部のプログラムを起動して**解く
/// （PATH に `zstd` があれば `.tar.zst` を `zstd -d` で読むのを実測）。手元の任意のファイルで外部のプログラムを起動しない。
///
/// **tar を読む開き方（zip 系以外）では gzip だけ**（作者の確認事項 B）。bzip2・xz などは、小さなファイルを libarchive の
/// 1 回の呼び出しの中で巨大に膨らませられる（実測: 1.4 KB の bzip2 の tar が、古い GNU の sparse の拡張ブロックの連なりで
/// ヘッダを 1 つ読むだけで 1 GiB を歩き 3.4 秒）。1 回の呼び出しの中は外から止められないので、膨らみ方が約 1000 倍で
/// 頭打ちの gzip だけにする。zip 系は今どおり（自前で解けるフィルタ全部）。
enum LibarchiveFormats {
    /// tar を有効にしない拡張子（標準の zip 系と、zip でできた EPUB）。
    static let zipFamilyExtensions: Set<String> = ["zip", "cbz", "rar", "cbr", "7z", "cb7", "epub"]

    /// libarchive のフィルタ（`archive_read_support_filter_all` が登録するものと同じ並び）。
    enum Filter: CaseIterable, Sendable {
        case bzip2, compress, gzip, grzip, lrzip, lz4, lzip, lzma, lzop, rpm, uu, xz, zstd

        /// 登録する。自前で解けるなら `ARCHIVE_OK`、外部のプログラムを使うなら `ARCHIVE_WARN` が返る。
        func register(_ archive: OpaquePointer) -> Int32 {
            switch self {
            case .bzip2: archive_read_support_filter_bzip2(archive)
            case .compress: archive_read_support_filter_compress(archive)
            case .gzip: archive_read_support_filter_gzip(archive)
            case .grzip: archive_read_support_filter_grzip(archive)
            case .lrzip: archive_read_support_filter_lrzip(archive)
            case .lz4: archive_read_support_filter_lz4(archive)
            case .lzip: archive_read_support_filter_lzip(archive)
            case .lzma: archive_read_support_filter_lzma(archive)
            case .lzop: archive_read_support_filter_lzop(archive)
            case .rpm: archive_read_support_filter_rpm(archive)
            case .uu: archive_read_support_filter_uu(archive)
            case .xz: archive_read_support_filter_xz(archive)
            case .zstd: archive_read_support_filter_zstd(archive)
            }
        }
    }

    /// この Mac の libarchive が自前で解けるフィルタ。捨てる archive に 1 回だけ登録して確かめる
    /// （登録すると取り消せないので、本番の archive には自前のものだけを登録する）。
    static let builtInFilters: [Filter] = {
        guard let probe = archive_read_new() else { return [] }
        defer { archive_read_free(probe) }
        return Filter.allCases.filter { $0.register(probe) == ARCHIVE_OK }
    }()

    /// その URL で登録するフィルタ。tar を読む開き方は gzip だけ、zip 系は自前で解けるもの全部。
    static func filters(for url: URL) -> [Filter] {
        readsTar(url) ? builtInFilters.filter { $0 == .gzip } : builtInFilters
    }

    /// `archive_read_new` の直後、open の前に呼ぶ。
    static func enable(_ archive: OpaquePointer, for url: URL) {
        archive_read_support_format_zip(archive)
        archive_read_support_format_rar(archive)
        archive_read_support_format_rar5(archive)
        archive_read_support_format_7zip(archive)
        if readsTar(url) {
            archive_read_support_format_tar(archive)
            // `._` で始まるエントリの AppleDouble（macOS のメタデータ）を、libarchive は archive_entry_size ぶん上限なしで
            // メモリに読む（予算に見えないメモリ）。StackNest は使わないので切る。`._x` は普通のエントリとして見える。
            let rc = archive_read_set_format_option(archive, "tar", "mac-ext", nil)   // nil で切る（"0" は空でない文字列＝入）
            assert(rc == ARCHIVE_OK, "tar mac-ext option rejected")
        }
        for filter in filters(for: url) {
            _ = filter.register(archive)
        }
    }

    /// その URL で tar を有効にするか。
    static func readsTar(_ url: URL) -> Bool {
        !zipFamilyExtensions.contains(url.pathExtension.lowercased())
    }
}

/// G64: tar を読む仕事の上限（1 回開くごと）。
///
/// tar には索引が無いので、エントリを探す・数えるたびにアーカイブ全体を頭から歩く。外側が圧縮されていれば、読み飛ばす
/// エントリも全部解く。小さな細工したファイル（大きな 0 の並びを圧縮で包んだ tar・エントリが極端に多い tar・中身より大きい
/// サイズを申告するエントリ・ヘッダの前に続く特別なヘッダ）で、読む側のスレッドを長く塞げてしまう
/// （実測 2026-10-09: 852 バイトの bzip2 の tar が 1 GiB を申告し、読み飛ばすだけで 3.4 秒）。
/// `ArchiveEntrySizeLimit`（512 MiB）は 1 エントリのメモリしか縛らないので、歩く量そのものを縛る。
///
/// 数えるのは、ヘッダを 1 つ読むたびの (1) エントリの数、(2) 解いた後の位置（`archive_filter_bytes(_, 0)`＝libarchive が
/// 実際に歩いた量。pax・GNU の長い名前・sparse の拡張ブロックなど、ヘッダの手前で歩いた分も入る）とこれから読むエントリの
/// 申告サイズの和、(3) 申告サイズの合計（sparse のエントリは中身より大きな論理サイズを申告できる）。1 回のヘッダの読みの中は
/// 止められないが、その中で歩ける量は libarchive 自身の上限（特別なヘッダ＝pax・GNU の長い名前は 1 つ 1 MiB まで・続けて 32 個まで。
/// macOS の libarchive 3.7.4 で実測 2026-10-09: 1 MiB＋1 バイトで「Special header too large」、33 個目で「Too many special headers」）と、
/// gzip の膨らみ方（約 1000 倍）で頭打ちになる（`LibarchiveFormats` を参照）。
///
/// **この予算が縛れないもの（受け入れ済み・G64 fix1 I1）:** (1) 1 回のヘッダの読みの中、(2) 1 つのエントリのデータ読み飛ばし。
/// sparse のエントリは、申告サイズ（実サイズ）と読み飛ばしで実際に消費する量（格納サイズ）が違いうるので、ヘッダ 1 つの読みと
/// データ読み飛ばし 1 回は、予測を超えうる（超過は次のヘッダで初めて見える）。どちらも外側の圧縮の膨らみ方（gzip で約 1000 倍）×
/// ファイルの大きさで頭打ちになり、同じ種類の残りとして受け入れる。データの**読み出し**（`archive_read_data`）は別で、
/// sparse の穴の 0 埋めが申告サイズを超えて出続けるのを、エントリごとの「出てきた量 ≤ 申告サイズ」の上限（`producedLimit`・C1）で止める。
///
/// **メモリの残り（既知・受け入れ済み・G64 fix2）:** 1 回のヘッダの読みは、解いたヘッダのデータに比例するメモリを確保しうる。
/// 例えば pax の GNU.sparse 1.0 の地図は、地図のエントリ 1 つにつき約 32 バイトを確保し、libarchive に数の上限が無い。
/// gzip ならファイルの大きさの約 1000 倍に達しうる。これは歩く量の予算では縛れない（AppleDouble の blob は `mac-ext` を切って塞いだ）。
///
/// 上限を超えたら、その位置でヘッダが読めなくなったのと同じに扱う（読めた分があれば打ち切り＝破損、無ければ開けない）。
/// 新しい文言は出さない。**tar のときだけ数える**（zip・rar・7z は今のまま）。
public struct TarWalkLimits: Sendable, Equatable {
    /// 1 回に歩くエントリの数の上限。
    public let maxEntries: Int
    /// 歩いてよい量の固定の部分。
    public let baseBytes: Int64
    /// ファイルの大きさ 1 バイトあたりに足す量。
    public let bytesPerFileByte: Int64
    /// ファイルの大きさで足す量の頭打ち（sparse ファイルなど、論理サイズが膨らんだファイルで上限が膨らまないように）。
    public let maxScaledBytes: Int64

    public init(maxEntries: Int, baseBytes: Int64, bytesPerFileByte: Int64, maxScaledBytes: Int64) {
        self.maxEntries = maxEntries
        self.baseBytes = baseBytes
        self.bytesPerFileByte = bytesPerFileByte
        self.maxScaledBytes = maxScaledBytes
    }

    /// 歩いてよい量 = `baseBytes` ＋ min(`bytesPerFileByte` × ファイルの大きさ, `maxScaledBytes`)。
    func limitBytes(fileSize: Int64) -> Int64 {
        let (scaled, overflow) = bytesPerFileByte.multipliedReportingOverflow(by: max(0, fileSize))
        let capped = overflow ? maxScaledBytes : min(scaled, maxScaledBytes)
        let (sum, overflow2) = baseBytes.addingReportingOverflow(capped)
        return overflow2 ? Int64.max : sum
    }

    /// 既定（作者への報告 2026-10-09）。漫画の書庫は数千ページ・数 GB で、画像は既に圧縮されているので外側の圧縮で縮むのは
    /// 高々数倍。エントリ 10 万・256 MiB ＋ ファイルの 64 倍（頭打ち 64 GiB）は、それに大きく余裕がある。
    /// 細工したファイルでも、1 回開くごとの仕事はおおよそ 256 MiB ＋ 64 × ファイルの大きさ（＋1 回のヘッダの読みの分）まで。
    public static let standard = TarWalkLimits(maxEntries: 100_000, baseBytes: 256 << 20, bytesPerFileByte: 64,
                                               maxScaledBytes: 64 << 30)
}

/// `TarWalkLimits` を 1 回開くごとに数える。ヘッダを 1 つ読んだ直後、データを読む・読み飛ばす前に `exceeds` を呼ぶ。
struct TarWalkBudget {
    /// 上限を超えたときに投げるエラーの理由（ログ用・永続化はしない。`QuickIntegrityScanner` が固定の分類名に写す）。
    static let exceededReason = "archive walk limit exceeded"
    /// tar のエントリのデータが、ヘッダの申告サイズより多く出てきたときの理由（sparse の穴の 0 埋めなど）。
    static let overrunReason = "tar entry data exceeds declared size"

    /// tar 系のエントリで、サイズが設定されているときの「読んでよい量」（max(0, 申告サイズ)）。それ以外（zip・rar・7z・
    /// サイズ未設定のストリーミング）は nil＝この上限を掛けない。
    /// GNU sparse のエントリは、実サイズ 0 のまま sparse の開始位置を 2^N にでき、`archive_read_data` は穴を 0 で埋めて
    /// 最大 2^N バイトを出す。ヘッダ時点の予算には見えないので、出てきた量を申告サイズで縛る（G64 fix1・C1）。
    static func producedLimit(_ archive: OpaquePointer, entry: OpaquePointer) -> Int64? {
        guard archive_format(archive) & ARCHIVE_FORMAT_BASE_MASK == ARCHIVE_FORMAT_TAR,
              archive_entry_size_is_set(entry) != 0 else { return nil }
        return max(0, archive_entry_size(entry))
    }

    private let maxEntries: Int
    private let limitBytes: Int64
    private var entries = 0
    private var declaredBytes: Int64 = 0

    init(url: URL, limits: TarWalkLimits) {
        // シンボリックリンクは辿る（辿らないとリンク自身の大きさ＝数十バイトになり、上限が潰れる）。
        let resolved = url.resolvingSymlinksInPath()
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: resolved.path))?[.size] as? NSNumber)?.int64Value ?? 0
        self.maxEntries = limits.maxEntries
        self.limitBytes = limits.limitBytes(fileSize: fileSize)
    }

    /// 読めたヘッダ（`status` が OK か WARN）が tar のエントリで、それを数えると上限を超えるなら true。
    /// 読めなかったヘッダ・tar でない形式（zip・rar・7z）は数えずに false。
    mutating func exceeds(_ archive: OpaquePointer, header status: Int32, entry: OpaquePointer?) -> Bool {
        guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let entry else { return false }
        guard archive_format(archive) & ARCHIVE_FORMAT_BASE_MASK == ARCHIVE_FORMAT_TAR else { return false }
        entries += 1
        let size = max(0, archive_entry_size(entry))
        let (declared, overflow) = declaredBytes.addingReportingOverflow(size)
        declaredBytes = overflow ? Int64.max : declared
        // libarchive が実際に歩いた量（解いた後の位置）＋このエントリを読む・読み飛ばす量。
        let walked = max(0, archive_filter_bytes(archive, 0))
        let (ahead, overflow2) = walked.addingReportingOverflow(size)
        let projected = overflow2 ? Int64.max : ahead
        return entries > maxEntries || declaredBytes > limitBytes || projected > limitBytes
    }
}
