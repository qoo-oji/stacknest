// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import OSLog
#if canImport(QuickLookThumbnailing)
import QuickLookThumbnailing
#endif

/// G64: 足した拡張子の本の表紙の最後の手段（macOS の Quick Look の縮小画像）。
/// `BookImporter` と `CoverRefresher.extractCoverData` が受け取る継ぎ目で、テストは偽物を渡す
/// （CI の Quick Look のサービスには頼らない。本物は smoke で確かめる）。
public protocol CoverThumbnailing: Sendable {
    /// 長辺 `maxPixelSize` 以下・透明を白で塗った JPEG。作れなければ nil（生成器が無い・時間切れ・読めない）。
    func coverJPEG(for url: URL, maxPixelSize: Int) async -> Data?
}

/// G64: 表紙の JPEG を作る（透明を白で塗る）。
public enum CoverJPEG {
    /// JPEG の品質（`CoverImageResizer` と同じ値）。
    public static let quality = 0.85

    /// 透明な部分を白で塗ってから JPEG（長辺 `maxPixelSize` 以下）にする。白で塗らないと、書類の縮小画像の
    /// 周りの透明な影が黒くなる。
    public static func whiteBacked(_ image: CGImage, maxPixelSize: Int) -> Data? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, maxPixelSize > 0 else { return nil }
        let scale = min(1.0, Double(maxPixelSize) / Double(max(width, height)))
        let w = max(1, Int((Double(width) * scale).rounded()))
        let h = max(1, Int((Double(height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flattened = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, flattened,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// 画像ファイルのバイトを ImageIO で読み、白で塗った JPEG に書き直す（足した画像の表紙）。
    /// `CoverImageResizer.resizeJPEG` と違い、**小さくても必ず書き直す**（`.jxl`・`.avif` のまま `thumbnail.jpg` に
    /// 入ると、Web のブラウザで表示できないことがある）。読めなければ nil。
    public static func fromImageData(_ data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // EXIF の向きを反映
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return whiteBacked(image, maxPixelSize: maxPixelSize)
    }
}

#if canImport(QuickLookThumbnailing)

/// G64: `QLThumbnailGenerator` の継ぎ目（テストは返らない偽物・すぐ返す偽物を渡す）。
protocol QuickLookGenerating: Sendable {
    /// 生成を始める。終わったら `completion` を呼ぶ（取り消した後は呼ばないことがある）。
    func start(_ request: QLThumbnailGenerator.Request, completion: @escaping @Sendable (CGImage?) -> Void)
    func cancel(_ request: QLThumbnailGenerator.Request)
}

/// 本物（Quick Look のサービスは別プロセス。待つのは呼び出し側のタスク）。
struct SystemQuickLookGenerator: QuickLookGenerating {
    func start(_ request: QLThumbnailGenerator.Request, completion: @escaping @Sendable (CGImage?) -> Void) {
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            completion(representation?.cgImage)
        }
    }

    func cancel(_ request: QLThumbnailGenerator.Request) {
        QLThumbnailGenerator.shared.cancel(request)
    }
}

/// G64: Quick Look の縮小画像を表紙の JPEG にする。
public struct QuickLookCoverThumbnailer: CoverThumbnailing {
    /// 待つ上限（作者の決定 2026-10-08）。超えたら取り消して失敗扱い。**上限はここ 1 か所**。
    public static let defaultTimeout: Duration = .seconds(10)
    /// 頼む縮小画像の種類。**`.icon` は頼まない**（頼むと、生成器の無い形式で書類のアイコンが「成功」として返る）。
    /// `.lowQualityThumbnail` は埋め込みの縮小画像などで、中身の絵なので受け取ってよい。
    static let representationTypes: QLThumbnailGenerator.Request.RepresentationTypes = [.lowQualityThumbnail, .thumbnail]

    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "QuickLookCoverThumbnailer")

    private let timeout: Duration
    private let generator: any QuickLookGenerating

    public init(timeout: Duration = Self.defaultTimeout) {
        self.init(timeout: timeout, generator: SystemQuickLookGenerator())
    }

    init(timeout: Duration, generator: any QuickLookGenerating) {
        self.timeout = timeout
        self.generator = generator
    }

    /// 要求を作る（正方形 `maxPixelSize`・倍率 1）。
    static func makeRequest(url: URL, maxPixelSize: Int) -> QLThumbnailGenerator.Request {
        QLThumbnailGenerator.Request(fileAt: url,
                                     size: CGSize(width: maxPixelSize, height: maxPixelSize),
                                     scale: 1,
                                     representationTypes: representationTypes)
    }

    public func coverJPEG(for url: URL, maxPixelSize: Int) async -> Data? {
        guard let image = await image(for: url, maxPixelSize: maxPixelSize) else {
            Self.logger.info("Quick Look thumbnail unavailable: \(url.path, privacy: .private)")
            return nil
        }
        return CoverJPEG.whiteBacked(image, maxPixelSize: maxPixelSize)
    }

    /// 生成を待つ。上限を過ぎたら `cancel` して nil（`VideoFrameExtractor` の 1 枚の上限と同じ作り）。
    func image(for url: URL, maxPixelSize: Int) async -> CGImage? {
        /// 続きを 1 回だけ再開する（生成の完了と時間切れのどちらか先）。
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<CGImage?, Never>?
            init(_ continuation: CheckedContinuation<CGImage?, Never>) { self.continuation = continuation }
            func resume(_ image: CGImage?) {
                lock.lock()
                let c = continuation
                continuation = nil
                lock.unlock()
                c?.resume(returning: image)
            }
        }
        // `QLThumbnailGenerator.Request` は Sendable ではないが、生成と取り消しはスレッド安全に扱えるので、
        // タスクへ渡すためだけの箱に入れる。
        struct RequestBox: @unchecked Sendable { let request: QLThumbnailGenerator.Request }
        let box = RequestBox(request: Self.makeRequest(url: url, maxPixelSize: maxPixelSize))
        let generator = self.generator
        let timeout = self.timeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            let once = Once(continuation)
            let timeoutTask = Task {
                // 取り消されたときは何もせずに抜ける（`try?` で握り潰すと、取り消し直後に cancel へ落ちる）。
                do { try await Task.sleep(for: timeout) } catch { return }
                generator.cancel(box.request)
                once.resume(nil)
            }
            generator.start(box.request) { image in
                timeoutTask.cancel()
                once.resume(image)
            }
        }
    }
}

#else

/// Quick Look の無い環境（将来の Linux のヘッドレスのサーバ）では、常に作れない。
public struct QuickLookCoverThumbnailer: CoverThumbnailing {
    public static let defaultTimeout: Duration = .seconds(10)
    public init(timeout: Duration = Self.defaultTimeout) {}
    public func coverJPEG(for url: URL, maxPixelSize: Int) async -> Data? { nil }
}

#endif
