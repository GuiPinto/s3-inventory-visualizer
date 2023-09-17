import Foundation

public final class NavigationHistory {
    private var entries: [UInt32]
    private var position: Int

    public init(root: UInt32) {
        entries = [root]
        position = 0
    }

    public var current: UInt32 { entries[position] }
    public var canGoBack: Bool { position > 0 }
    public var canGoForward: Bool { position + 1 < entries.count }

    public func navigate(to directory: UInt32) {
        guard directory != current else { return }

        if position + 1 < entries.count {
            entries.removeSubrange((position + 1)...)
        }

        entries.append(directory)
        position = entries.count - 1
    }

    public func goBack() -> UInt32? {
        guard canGoBack else { return nil }
        position -= 1
        return current
    }

    public func goForward() -> UInt32? {
        guard canGoForward else { return nil }
        position += 1
        return current
    }

    public func reset(to root: UInt32) {
        entries = [root]
        position = 0
    }
}
