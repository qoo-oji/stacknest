// SPDX-License-Identifier: MIT
import Testing
import Foundation
import CoreGraphics
import ImageIO
import QuickLookThumbnailing
@testable import AppCore

/// G64: Quick Look の縮小画像と、白で塗る JPEG（spec §6.6）。本物の Quick Look のサービスには頼らない。
@Suite("G64: Quick Look の表紙")
struct CoverThumbnailingTests {
    /// 生成の偽物。`image` を返す（nil なら返さない＝時間切れを作る）。取り消しを数える。
    final class FakeGenerator: QuickLookGenerating, @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = 0
        private var requests: [QLThumbnailGenerator.Request] = []
        private let image: CGImage?
        init(image: CGImage?) { self.image = image }
        var cancelCount: Int { lock.withLock { cancelled } }
        var started: [QLThumbnailGenerator.Request] { lock.withLock { requests } }
        func start(_ request: QLThumbnailGenerator.Request, completion: @escaping @Sendable (CGImage?) -> Void) {
            lock.withLock { requests.append(request) }
            guard let image else { return }        // 返らない
            DispatchQueue.global().async { completion(image) }
        }
        func cancel(_ request: QLThumbnailGenerator.Request) { lock.withLock { cancelled += 1 } }
    }

    /// 左半分が透明・右半分が黒の画像。
    private func halfTransparent(width: Int = 8, height: Int = 4) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return ctx.makeImage()!
    }

    /// JPEG を読み、(x, y) の画素の赤の値（0〜255）を返す。
    private func red(in jpeg: Data, x: Int, y: Int) throws -> Int {
        let src = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Int(pixel[0])
    }

    @Test("上限は 10 秒・頼むのは縮小画像だけ（.icon を頼まない）")
    func requestShape() {
        #expect(QuickLookCoverThumbnailer.defaultTimeout == .seconds(10))
        let request = QuickLookCoverThumbnailer.makeRequest(url: URL(fileURLWithPath: "/tmp/a.docx"), maxPixelSize: 1200)
        #expect(request.representationTypes == [.lowQualityThumbnail, .thumbnail])
        #expect(!request.representationTypes.contains(.icon))
        #expect(request.size == CGSize(width: 1200, height: 1200))
        #expect(request.scale == 1)
    }

    @Test("返らなければ上限で取り消して nil")
    func timeoutCancels() async {
        let generator = FakeGenerator(image: nil)
        let thumbnailer = QuickLookCoverThumbnailer(timeout: .milliseconds(50), generator: generator)
        // 偽物は完了を返さないので、上限が効かなければここで止まったままになる。
        let data = await thumbnailer.coverJPEG(for: URL(fileURLWithPath: "/tmp/a.docx"), maxPixelSize: 1200)
        #expect(data == nil)
        #expect(generator.cancelCount == 1)
        #expect(generator.started.count == 1)
    }

    @Test("返ったら取り消さず、透明を白で塗った JPEG")
    func completedImageIsWhiteBackedJPEG() async throws {
        let generator = FakeGenerator(image: halfTransparent())
        let thumbnailer = QuickLookCoverThumbnailer(timeout: .seconds(5), generator: generator)
        let data = try #require(await thumbnailer.coverJPEG(for: URL(fileURLWithPath: "/tmp/a.docx"), maxPixelSize: 1200))
        #expect(G64Fixtures.isJPEG(data))
        #expect(try red(in: data, x: 1, y: 1) > 230, "透明だった左は白")
        #expect(try red(in: data, x: 6, y: 1) < 40, "黒い右は黒のまま")
        // 取り消しの見張りは成功で止まる（後から発火しない）。
        try await Task.sleep(for: .milliseconds(50))
        #expect(generator.cancelCount == 0)
    }

    @Test("長辺を上限に縮める")
    func scalesDown() throws {
        let data = try #require(CoverJPEG.whiteBacked(halfTransparent(width: 400, height: 100), maxPixelSize: 100))
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 100)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 25)
    }

    @Test("足した画像の表紙は小さくても JPEG に書き直す・読めなければ nil")
    func imageDataIsAlwaysReencoded() {
        let png = G64Fixtures.png(width: 4, height: 4)
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(G64Fixtures.isJPEG(CoverJPEG.fromImageData(png, maxPixelSize: 1200)))
        #expect(CoverJPEG.fromImageData(G64Fixtures.noise, maxPixelSize: 1200) == nil)
    }
}
