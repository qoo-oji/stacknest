// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G50: 表紙の共通抽出（`CoverRefresher.extractCoverData`）に動画が通ることを固定する。
/// 実フレームの復号を伴うので、他のテストより時間がかかる。
@Suite("G50: 動画の表紙抽出")
struct VideoCoverRefresherTests {
    static var fixtureURL: URL? {
        Bundle.module.url(forResource: "sample-2s", withExtension: "mp4", subdirectory: "VideoFixtures")
    }

    @Test("自動（preferredName なし）で表紙が取れる")
    func extractsAutomatically() async throws {
        let url = try #require(Self.fixtureURL)
        let data = try await CoverRefresher.extractCoverData(sourceURL: url, preferredName: nil)
        #expect(data.count > 1000)
    }

    @Test("@t= を渡すとその場面から取れる")
    func extractsAtRequestedTime() async throws {
        let url = try #require(Self.fixtureURL)
        let name = CoverSource.videoTimeSentinel(forSeconds: 1.0)
        let data = try await CoverRefresher.extractCoverData(sourceURL: url, preferredName: name)
        #expect(data.count > 1000)
    }

    /// AVFoundation が開けない拡張子は、従来どおり「表紙を作れない形式」として扱う
    /// （エラーにはするが、取り込み自体は続く）。
    @Test("対応外の拡張子は unsupportedFormat")
    func unsupportedExtensionsFail() async throws {
        let source = try #require(Self.fixtureURL)
        for ext in ["mkv", "webm", "avi"] {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: source, to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            await #expect(throws: CoverRefreshError.unsupportedFormat) {
                _ = try await CoverRefresher.extractCoverData(sourceURL: tmp, preferredName: nil)
            }
        }
    }
}
