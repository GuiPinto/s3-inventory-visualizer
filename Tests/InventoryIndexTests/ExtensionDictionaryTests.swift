import XCTest
@testable import InventoryIndex

final class ExtensionDictionaryTests: XCTestCase {
    private func identifier(_ dictionary: ExtensionDictionary, _ basename: String) -> UInt16 {
        Array(basename.utf8).withUnsafeBufferPointer { dictionary.identifier(forBasename: $0) }
    }

    func testExtractionRules() {
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: "photo.JPG"), "jpg")
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: "archive.tar.gz"), "gz")
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: "noextension"), "")
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: "trailingdot."), "")
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: "toolong.abcdefghi"), "")
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: "eight.abcdefgh"), "abcdefgh")
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: "notalnum.jp-g"), "")
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: ".hidden"), "hidden")
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: ""), "")
    }

    func testInterningIsStableAndCaseInsensitive() {
        let dictionary = ExtensionDictionary()
        XCTAssertEqual(identifier(dictionary, "a.jpg"), 1)
        XCTAssertEqual(identifier(dictionary, "b.JPG"), 1)
        XCTAssertEqual(identifier(dictionary, "c.mp4"), 2)
        XCTAssertEqual(identifier(dictionary, "plain"), 0)
        XCTAssertEqual(dictionary.names, ["", "jpg", "mp4"])
    }

    func testOverflowMapsToOther() {
        let dictionary = ExtensionDictionary()

        for value in 0..<65_540 {
            _ = identifier(dictionary, "f.\(String(value, radix: 36))")
        }

        XCTAssertEqual(dictionary.names.count, 65_535)
        XCTAssertEqual(identifier(dictionary, "f.zzzzzz"), ExtensionDictionary.otherIdentifier)
    }
}
