// SPDX-License-Identifier: MIT
import Testing
import Foundation
import CoreGraphics
@testable import AppCore

@Suite("G50: 動画フレームの抽出")
struct VideoFrameExtractorTests {
    @Test("対応拡張子は mp4 / mov / m4v だけ")
    func supportedExtensions() {
        #expect(VideoFrameExtractor.isSupported(url: URL(fileURLWithPath: "/a/b.mp4")))
        #expect(VideoFrameExtractor.isSupported(url: URL(fileURLWithPath: "/a/b.MOV")))
        #expect(VideoFrameExtractor.isSupported(url: URL(fileURLWithPath: "/a/b.m4v")))
        #expect(!VideoFrameExtractor.isSupported(url: URL(fileURLWithPath: "/a/b.mkv")))
        #expect(!VideoFrameExtractor.isSupported(url: URL(fileURLWithPath: "/a/b.webm")))
        #expect(!VideoFrameExtractor.isSupported(url: URL(fileURLWithPath: "/a/b.avi")))
    }

    @Test("候補時刻は尺の 10% / 25% / 50%")
    func candidateTimes() {
        #expect(VideoFrameExtractor.candidateTimes(duration: 100) == [10, 25, 50])
        #expect(VideoFrameExtractor.candidateTimes(duration: 0).isEmpty)
        #expect(VideoFrameExtractor.candidateTimes(duration: -1).isEmpty)
        #expect(VideoFrameExtractor.candidateTimes(duration: .nan).isEmpty)
    }

    @Test("真っ黒・真っ白・単色のフレームは採らない")
    func frameQuality() {
        #expect(!FrameStatistics(mean: 0, standardDeviation: 0).isUsable)
        #expect(!FrameStatistics(mean: 255, standardDeviation: 0).isUsable)
        #expect(!FrameStatistics(mean: 128, standardDeviation: 2).isUsable)
        #expect(FrameStatistics(mean: 128, standardDeviation: 40).isUsable)
    }

    @Test("@t= センチネルの往復")
    func videoTimeSentinel() {
        #expect(CoverSource.videoTimeSentinel(forSeconds: 12.5) == "@t=12.500")
        #expect(CoverSource.videoTime(from: "@t=12.500") == 12.5)
        #expect(CoverSource.videoTime(from: "@external") == nil)
        #expect(CoverSource.videoTime(from: nil) == nil)
        #expect(CoverSource.videoTime(from: "cover.jpg") == nil)
        #expect(CoverSource.videoTime(from: "@t=") == nil)
        #expect(CoverSource.videoTime(from: "@t=abc") == nil)
        // 外部表紙の判定を汚さないこと
        #expect(!CoverSource.isExternal("@t=12.500"))
    }

    @Test("検体からフレームが取れる")
    func extractsFromFixture() async throws {
        let url = try #require(Self.fixtureURL)
        let data = try await VideoFrameExtractor.autoCoverData(url: url, maxPixelSize: 1200)
        #expect(data.count > 1000)
        let timed = try await VideoFrameExtractor.frameData(url: url, seconds: 1.0, maxPixelSize: 1200)
        #expect(timed.count > 1000)
    }

    @Test("対応外の形式は notAVideo")
    func unsupportedFile() async {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp4")
        try? Data("not a video".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        await #expect(throws: VideoFrameError.notAVideo) {
            _ = try await VideoFrameExtractor.autoCoverData(url: tmp, maxPixelSize: 1200)
        }
    }

    static var fixtureURL: URL? {
        Bundle.module.url(forResource: "sample-2s", withExtension: "mp4", subdirectory: "VideoFixtures")
    }

    // MARK: - 実画像に対する統計（復号は不要・合成した CGImage で確かめる）

    private static func solidImage(gray: UInt8) -> CGImage {
        makeImage { ctx, side in
            ctx.setFillColor(CGColor(gray: Double(gray) / 255.0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    private static func checkerImage() -> CGImage {
        makeImage { ctx, side in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            for y in stride(from: 0, to: side, by: 16) {
                for x in stride(from: 0, to: side, by: 16) where ((x / 16) + (y / 16)) % 2 == 0 {
                    ctx.fill(CGRect(x: x, y: y, width: 16, height: 16))
                }
            }
        }
    }

    private static func makeImage(_ draw: (CGContext, Int) -> Void) -> CGImage {
        let side = 128
        let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                            bytesPerRow: side, space: space,
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        draw(ctx, side)
        return ctx.makeImage()!
    }

    @Test("真っ黒な画像は表紙にしない")
    func solidBlackIsRejected() {
        let stats = VideoFrameExtractor.statistics(of: Self.solidImage(gray: 0))
        #expect(stats.standardDeviation < 1)
        #expect(!stats.isUsable)
    }

    @Test("真っ白・単色の画像も表紙にしない")
    func solidBrightIsRejected() {
        #expect(!VideoFrameExtractor.statistics(of: Self.solidImage(gray: 255)).isUsable)
        #expect(!VideoFrameExtractor.statistics(of: Self.solidImage(gray: 128)).isUsable)
    }

    @Test("模様のある画像は表紙にできる")
    func patternedImageIsUsable() {
        let stats = VideoFrameExtractor.statistics(of: Self.checkerImage())
        #expect(stats.standardDeviation > 6)
        #expect(stats.isUsable)
    }

    /// 暗いが真っ黒ではない場面を弾かないこと（線形の輝度で測ると弾いてしまう）。
    @Test("暗いが模様のある画像は弾かない")
    func dimPatternedImageIsUsable() {
        let dim = Self.makeImage { ctx, side in
            ctx.setFillColor(CGColor(gray: 20.0 / 255.0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            ctx.setFillColor(CGColor(gray: 70.0 / 255.0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side / 2))
        }
        let stats = VideoFrameExtractor.statistics(of: dim)
        #expect(stats.isUsable)
    }
}
