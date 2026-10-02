// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

/// G60 v3: 参照ファイルを渡してから確かめるまでの待ち（隠しキー・設定画面には出さない）。
@Suite("G60 v3: 確認までの待ち（隠しキー）")
@MainActor
struct ViewerUseCheckDelayTests {
    private func settings(_ value: Any?) -> (ViewerSettings, () -> Void) {
        let name = "g60v3-delay-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        if let value { suite.set(value, forKey: ViewerSettings.viewerUseCheckDelayKey) }
        return (ViewerSettings(defaults: suite), { suite.removePersistentDomain(forName: name) })
    }

    @Test func defaultIsFifteenSeconds() {
        #expect(ViewerSettings.viewerUseCheckDelayKey == "externalViewerUseCheckDelaySeconds")
        let (s, done) = settings(nil); defer { done() }
        #expect(s.viewerUseCheckDelay == .seconds(15))
    }

    @Test func hiddenKeyOverridesAndIsClamped() {
        let cases: [(Any, Duration)] = [
            (30, .seconds(30)),
            ("45", .seconds(45)),          // `defaults write … -string 45` でも効く
            (0.2, .seconds(1)),            // 下限 1 秒
            (10_000, .seconds(600)),       // 上限 600 秒
            (-5, .seconds(15)),            // 0 以下は既定
            ("abc", .seconds(15)),         // 数でなければ既定
        ]
        for (value, expected) in cases {
            let (s, done) = settings(value); defer { done() }
            #expect(s.viewerUseCheckDelay == expected, "\(value)")
        }
    }
}
