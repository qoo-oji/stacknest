// SPDX-License-Identifier: MIT
import AVKit
import SwiftUI

/// G50: 動画の表紙にする場面を選ぶシート。
/// 標準のプレイヤー（シークバー付き）で頭出しし、その時刻を呼び出し側へ返す。
/// 実際のフレーム抽出と保存は `AppState.setVideoSceneCover` が行う。
struct VideoCoverPickerSheet: View {
    let url: URL
    let onPicked: (Double) -> Void
    let onCancel: () -> Void

    @State private var player: AVPlayer

    init(url: URL, onPicked: @escaping (Double) -> Void, onCancel: @escaping () -> Void) {
        self.url = url
        self.onPicked = onPicked
        self.onCancel = onCancel
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("表紙にする場面を選んでください")
                .font(.headline)
            VideoPlayer(player: player)
                .frame(minWidth: 640, minHeight: 360)
            HStack {
                Text("再生・シークして、使いたい場面で止めてください")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル") {
                    player.pause()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("この場面を表紙にする") {
                    player.pause()
                    onPicked(player.currentTime().seconds)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onDisappear { player.pause() }
    }
}
