// SPDX-License-Identifier: MIT
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

public enum VideoFrameError: Error, Sendable, Equatable {
    /// AVFoundation がそのファイルを動画として開けない（mkv / webm / avi / 破損）
    case notAVideo
    /// 開けたがフレームを 1 枚も作れなかった
    case noUsableFrame
}

/// フレームの明るさの散らばり。真っ黒・真っ白・単色を弾くためだけに使う。
public struct FrameStatistics: Equatable, Sendable {
    public let mean: Double
    public let standardDeviation: Double

    public init(mean: Double, standardDeviation: Double) {
        self.mean = mean
        self.standardDeviation = standardDeviation
    }

    /// 表紙として使えるか。閾値は 2026-09-06 の実測で決めた値。
    public var isUsable: Bool {
        mean >= 8 && mean <= 247 && standardDeviation >= 6
    }
}

/// G50: 動画から表紙用の 1 枚を取り出す。
///
/// AVFoundation が開けるのは mp4 / mov / m4v で、mkv・webm・avi は開けない（2026-09-06 実測）。
/// 対応外はエラーにせず、呼び出し側で「表紙を作れなかった本」として扱う。
public enum VideoFrameExtractor {
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "video-frame")

    /// AVFoundation が扱える動画の拡張子。`BookCategory` の `.video` はこれより広い。
    public static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v"]

    public static func isSupported(url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// 自動で拾うフレームの候補時刻（秒）。冒頭は黒画面やロゴが多いので 10% から入る。
    public static func candidateTimes(duration: Double) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        return [0.10, 0.25, 0.50].map { duration * $0 }
    }

    /// 64×64 のグレースケールに落として平均と標準偏差を出す。
    public static func statistics(of image: CGImage) -> FrameStatistics {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let space = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(data: &pixels, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side,
                                  space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else {
            return FrameStatistics(mean: 0, standardDeviation: 0)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let values = pixels.map(Double.init)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return FrameStatistics(mean: mean, standardDeviation: variance.squareRoot())
    }

    /// 指定時刻のフレームを JPEG で返す（手動のシーン選択・`@t=` の再生成に使う）。
    public static func frameData(url: URL, seconds: Double, maxPixelSize: Int) async throws -> Data {
        let (asset, _) = try await openAsset(url: url)
        let generator = makeGenerator(asset: asset, maxPixelSize: maxPixelSize)
        // 手動指定は「その場面」を返したい。ただし許容誤差を完全に切ると、直前のキーフレームから
        // 全フレームを復号し直すことになり、長い動画で待ち時間が跳ね上がる。1/30 秒あれば
        // シーン選択としては十分に同じ場面になる。
        let tolerance = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        guard let (image, _) = try? await generator.image(at: time),
              let data = jpegData(from: image) else {
            throw VideoFrameError.noUsableFrame
        }
        return data
    }

    /// 自動で選んだフレームを JPEG で返す。真っ黒・単色でない最初の候補を採り、
    /// どれも駄目なら最初に取れたフレームを使う（表紙が無いよりまし）。
    public static func autoCoverData(url: URL, maxPixelSize: Int) async throws -> Data {
        let (asset, duration) = try await openAsset(url: url)
        let generator = makeGenerator(asset: asset, maxPixelSize: maxPixelSize)
        // 自動はどこか 1 枚拾えればよいので、許容誤差を広く取って探索を速くする。
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var fallback: Data?
        for seconds in candidateTimes(duration: duration) {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let (image, _) = try? await generator.image(at: time) else { continue }
            guard let data = jpegData(from: image) else { continue }
            if statistics(of: image).isUsable { return data }
            if fallback == nil { fallback = data }
        }
        if let fallback { return fallback }
        throw VideoFrameError.noUsableFrame
    }

    // MARK: - private

    private static func openAsset(url: URL) async throws -> (AVURLAsset, Double) {
        guard isSupported(url: url) else { throw VideoFrameError.notAVideo }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              let tracks = try? await asset.loadTracks(withMediaType: .video),
              !tracks.isEmpty else {
            throw VideoFrameError.notAVideo
        }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw VideoFrameError.notAVideo }
        return (asset, seconds)
    }

    private static func makeGenerator(asset: AVURLAsset, maxPixelSize: Int) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true   // 回転を反映する
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        return generator
    }

    private static func jpegData(from image: CGImage, quality: Double = 0.8) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
