import AppKit
import InventoryIndex

final class ClassMixBarView: NSView {
    var bytesByStorageClass: [UInt64] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let total = bytesByStorageClass.reduce(UInt64(0)) { $0 &+ $1 }

        guard total > 0 else { return }
        let barRect = bounds.insetBy(dx: 2, dy: (bounds.height - 8) / 2)
        var x = barRect.minX

        for (slot, bytes) in bytesByStorageClass.enumerated() where bytes > 0 {
            let width = barRect.width * CGFloat(Double(bytes) / Double(total))
            TreemapPalette.color(forStorageClass: slot).setFill()
            NSBezierPath(rect: NSRect(x: x, y: barRect.minY, width: max(width, 0.5), height: barRect.height)).fill()
            x += width
        }
    }
}
