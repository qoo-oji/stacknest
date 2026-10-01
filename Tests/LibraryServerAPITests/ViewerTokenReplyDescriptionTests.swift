// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryServerAPI

/// G60 最終レビュー M-4: 本専用トークンの応答 DTO を print・文字列補間・テストの失敗表示に出しても、
/// 平文のトークンが出ない。
@Suite("ViewerTokenReply の表示はトークンを伏せる")
struct ViewerTokenReplyDescriptionTests {
    private func sample() -> ViewerTokenReply {
        ViewerTokenReply(token: "SECRET-TOKEN", expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }

    @Test func descriptionsNeverShowTheToken() {
        #expect(!String(describing: sample()).contains("SECRET-TOKEN"))
        #expect(!String(reflecting: sample()).contains("SECRET-TOKEN"))
        #expect(!"\(sample())".contains("SECRET-TOKEN"))
        #expect(String(describing: sample()).contains("<redacted>"))
    }

    /// 伏せるのは表示だけ。JSON（ワイヤ形式）にはトークンが載る。
    @Test func encodingStillCarriesTheToken() throws {
        let data = try JSONEncoder().encode(sample())
        #expect(String(decoding: data, as: UTF8.self).contains("SECRET-TOKEN"))
    }
}
