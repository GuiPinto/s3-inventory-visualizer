import AppKit
import InventoryIndex

struct LegendEntry {
    var color: NSColor
    var label: String
    var bytes: UInt64
    var category: Int
}

final class LegendView: NSView {
    var onSelect: ((Int?) -> Void)?
    private(set) var highlighted: Int?
    private var entries: [LegendEntry] = []
    private let stack = NSStackView()

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 34) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(hexString: "0E1014").setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: 1)).fill()
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(hexString: "23272F").cgColor
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func entryClicked(_ sender: NSButton) {
        let category = sender.tag
        highlighted = highlighted == category ? nil : category
        onSelect?(highlighted)
        refreshHighlight()
    }

    private func refreshHighlight() {
        for view in stack.arrangedSubviews {
            guard let button = view as? NSButton else { continue }
            button.layer?.borderWidth = button.tag == highlighted ? 1 : 0
            button.layer?.borderColor = NSColor(white: 0.9, alpha: 0.9).cgColor
            button.layer?.cornerRadius = 4
        }
    }

    func update(entries newEntries: [LegendEntry], totalBytes: UInt64, units: ByteUnits) {
        entries = newEntries
            .filter { totalBytes == 0 || Double($0.bytes) / Double(totalBytes) >= 0.0005 }
            .sorted { $0.bytes > $1.bytes }

        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for entry in entries {
            let button = NSButton(title: "", target: self, action: #selector(entryClicked(_:)))
            button.isBordered = false
            button.tag = entry.category
            button.wantsLayer = true
            let share = totalBytes == 0 ? 0 : Double(entry.bytes) * 100 / Double(totalBytes)
            let text = NSMutableAttributedString()
            text.append(NSAttributedString(
                string: "● ",
                attributes: [ .foregroundColor: entry.color, .font: NSFont.systemFont(ofSize: 13)]
            ))
            text.append(NSAttributedString(
                string: entry.label + "  ",
                attributes: [ .foregroundColor: NSColor(white: 0.88, alpha: 1), .font: NSFont.systemFont(ofSize: 11)]
            ))
            let detail = formatByteCount(entry.bytes, units: units) + String(format: "  %.1f%%", share)
            text.append(NSAttributedString(
                string: detail,
                attributes: [ .foregroundColor: NSColor(white: 0.55, alpha: 1), .font: NSFont.systemFont(ofSize: 11)]
            ))
            button.attributedTitle = text
            stack.addArrangedSubview(button)
        }

        refreshHighlight()
    }

    func clearHighlight() {
        highlighted = nil
        refreshHighlight()
    }
}
