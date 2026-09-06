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
}
