// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("BookCategory.supportedExtensions")
struct BookCategorySupportedExtensionsTests {
    @Test
    func includesAllArchiveExtensions() {
        for ext in ["zip", "cbz", "cbr", "rar", "7z", "cb7", "cbt", "tar"] {
            #expect(BookCategory.supportedExtensions.contains(ext))
        }
    }

    @Test
    func includesAllImageExtensions() {
        for ext in ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"] {
            #expect(BookCategory.supportedExtensions.contains(ext))
        }
    }

    @Test
    func includesAllVideoExtensions() {
        for ext in ["mp4", "mov", "avi", "mkv", "webm", "m4v"] {
            #expect(BookCategory.supportedExtensions.contains(ext))
        }
    }

    @Test
    func includesAllTextExtensions() {
        for ext in ["pdf", "epub", "txt", "md", "rtf"] {
            #expect(BookCategory.supportedExtensions.contains(ext))
        }
    }

    @Test
    func excludesUnknown() {
        #expect(!BookCategory.supportedExtensions.contains("docx"))
        #expect(!BookCategory.supportedExtensions.contains("xlsx"))
        #expect(!BookCategory.supportedExtensions.contains(""))
    }

    @Test
    func cb7ClassifiesAsArchive() {
        #expect(BookCategory.classify(path: "/x/a.cb7") == .archive)
    }

    @Test("G64: 標準は 29 個（cbt・tar を含む）で、足した拡張子は入らない")
    func has29PresetExtensions() {
        #expect(BookCategory.supportedExtensions.count == 29)
        #expect(!BookCategory.supportedExtensions.contains("tgz"))
    }
}
