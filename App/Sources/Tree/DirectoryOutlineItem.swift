import Foundation

final class DirectoryOutlineItem: NSObject {
    enum Kind {
        case directory(UInt32)
        case filesGroup(UInt32)
        case file(UInt64, UInt32)
        case moreFiles(UInt32, remaining: UInt64)
    }

    let kind: Kind
    var cachedChildren: [DirectoryOutlineItem]?

    init(kind: Kind) {
        self.kind = kind
        super.init()
    }

    var directoryIdentifier: UInt32 {
        switch kind {
        case .directory(let identifier): return identifier
        case .filesGroup(let identifier): return identifier
        case .file(_, let identifier): return identifier
        case .moreFiles(let identifier, _): return identifier
        }
    }

    var isSelectable: Bool {
        if case .moreFiles = kind {
            return false
        }

        return true
    }
}
