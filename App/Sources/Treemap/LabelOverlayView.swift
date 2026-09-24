import AppKit
import TreemapLayout

final class LabelOverlayView: NSView {
    private var labels: [LayoutLabel] = []
    private var scale: CGFloat = 1

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(labels: [LayoutLabel], scale: CGFloat) {
        // A nested box starts at its parent's top-left corner, so every level of a chain wants to
        // write its name in the same place. Sorting by area and skipping collisions leaves the
        // outermost, and therefore most useful, name of each chain.
        self.labels = labels.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
        self.scale = max(scale, 0.5)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !labels.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            .shadow: shadow,
        ]
        let measuring: [NSAttributedString.Key: Any] = [.font: font]

        var placed: [NSRect] = []
        placed.reserveCapacity(labels.count)

        for label in labels {
            let box = NSRect(
                x: label.rect.x / scale,
                y: label.rect.y / scale,
                width: label.rect.width / scale,
                height: label.rect.height / scale
            )
            let available = box.width - 8

            guard available > 24, box.height > 15 else { continue }

            let text = label.text.isEmpty ? "(root)" : label.text
            let measured = (text as NSString).size(withAttributes: measuring)
            let width = min(measured.width, available)
            let textRect = NSRect(x: box.minX + 4, y: box.minY + 2, width: width, height: 14)

            // Keep a little air around each name so two of them never touch.
            let claimed = textRect.insetBy(dx: -3, dy: -2)

            if placed.contains(where: { $0.intersects(claimed) }) {
                continue
            }

            placed.append(claimed)

            guard textRect.intersects(dirtyRect) else { continue }
            (text as NSString).draw(
                with: textRect,
                options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                attributes: attributes
            )
        }
    }
}
