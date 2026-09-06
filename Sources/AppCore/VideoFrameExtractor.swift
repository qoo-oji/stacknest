// SPDX-License-Identifier: MIT
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
    ///
    /// 色空間は **gamma 2.2**（`linearGray` ではない）。閾値は見た目の 0〜255 で決めており、
    /// 線形の輝度に直すと暗い場面が軒並み「真っ黒」と判定されてしまう。
    public static func statistics(of image: CGImage) -> FrameStatistics {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) else {
            return FrameStatistics(mean: 0, standardDeviation: 0)
        }
        // 配列の可変ポインタは `withUnsafeMutableBytes` の中だけで使う
        // （`&pixels` を CGContext に渡すとスコープ外へ脱出して未定義動作になる）。
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let ctx = CGContext(data: base, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side,
                                      space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return FrameStatistics(mean: 0, standardDeviation: 0) }
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
        guard let image = await image(from: generator, at: time),
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
            guard let image = await image(from: generator, at: time) else { continue }
            guard let data = jpegData(from: image) else { continue }
            if statistics(of: image).isUsable { return data }
            if fallback == nil { fallback = data }
        }
        if let fallback { return fallback }
        throw VideoFrameError.noUsableFrame
    }

    // MARK: - private

    /// フレーム 1 枚の生成に上限時間を設ける。
    ///
    /// `AVAssetImageGenerator` は復号の当てが外れると返ってこないことがある
    /// （macOS 側の VideoToolbox が詰まると、正常なファイルでも応答が来なくなるのを実際に踏んだ）。
    /// 取り込みは 1 冊ずつこれを待つので、上限が無いと**書庫の取り込み全体が止まる**。
    /// 期限を過ぎたら生成を取り消し、その本は「表紙を作れなかった」として先へ進める。
    private static func image(
        from generator: AVAssetImageGenerator,
        at time: CMTime,
        timeout: Duration = .seconds(20)
    ) async -> CGImage? {
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
        // `AVAssetImageGenerator` は Sendable ではないが、生成要求と取り消しはスレッド安全に
        // 扱えるので、タスクへ渡すためだけの箱に入れる。
        struct Box: @unchecked Sendable { let generator: AVAssetImageGenerator }
        let box = Box(generator: generator)
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            let once = Once(continuation)
            // 期限切れのとき、復号側のタスクは残るが呼び出し側は先へ進める。
            Task {
                let result = try? await box.generator.image(at: time)
                once.resume(result?.image)
            }
            Task {
                try? await Task.sleep(for: timeout)
                box.generator.cancelAllCGImageGeneration()
                once.resume(nil)
            }
        }
    }

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
