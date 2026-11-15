import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Poki

@MainActor
final class TextAttachmentTests: XCTestCase {
    func testPickerAndReaderSupportTextExtensions() throws {
        for ext in ["json", "md", "markdown", "txt"] {
            let type = try XCTUnwrap(UTType(filenameExtension: ext))
            XCTAssertTrue(AttachmentReader.fileTypes.contains { type.conforms(to: $0) })
            try withFile(ext, Data("hello".utf8)) { url in
                XCTAssertEqual(try AttachmentReader.file(url).textContent, "hello")
            }
        }
    }

    func testTextSizeAndEncodingAreCheckedBeforeSending() throws {
        try withFile("txt", Data(repeating: 65, count: 100_000)) { url in
            XCTAssertEqual(try AttachmentReader.file(url).textContent?.utf8.count, 100_000)
        }
        try withFile("txt", Data(repeating: 65, count: 100_001)) { url in
            XCTAssertThrowsError(try AttachmentReader.file(url)) {
                guard case AttachmentReader.Failure.tooLarge = $0 else { return XCTFail("\($0)") }
            }
        }
        try withFile("txt", Data([0xff])) { url in
            XCTAssertThrowsError(try AttachmentReader.file(url)) {
                guard case AttachmentReader.Failure.invalidUTF8 = $0 else { return XCTFail("\($0)") }
            }
        }
    }

    func testFileErrorsUsePokisLanguageInsteadOfTheSystemLanguage() {
        let saved = AppLocalization.shared.preference
        defer { AppLocalization.shared.preference = saved }
        let keys: [LocalizedStringResource] = ["Text files must be 100 KB or smaller.", "This text file must use UTF-8 encoding.", "Only images, PDFs, JSON, Markdown, and plain text files can be added."]
        for language in ["zh-Hans", "zh-Hant"] {
            AppLocalization.shared.preference = language
            for key in keys {
                let value = AppLocalization.text(key)
                XCTAssertFalse(value.hasPrefix("Text files") || value.hasPrefix("This text") || value.hasPrefix("Only images"))
                XCTAssertTrue(value.contains(language == "zh-Hans" ? "文件" : "檔案"))
            }
        }
    }

    private func withFile(_ ext: String, _ data: Data, check: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try check(url)
    }
}
