import Foundation

public enum ImportError: Error, Equatable {
    case invalidManifest(String)
    case missingDataFiles([String])
    case corruptGzip(file: String, detail: String)
    case rowTooLong(file: String)
    case tooManyParseErrors(file: String, count: Int)
    case notKeySorted(file: String, previousKey: String, key: String)
    case directoryReentered(path: String)
    case tooManyFiles
    case outputExists(URL)
    case cancelled
    case systemCall(String, errno: Int32)
}
