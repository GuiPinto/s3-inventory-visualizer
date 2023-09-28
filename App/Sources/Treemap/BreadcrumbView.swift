import AppKit

final class BreadcrumbView: NSView {
    var onSelect: ((UInt32) -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onUp: (() -> Void)?

    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let chipStack = NSStackView()

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 38) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(hexString: "0E1014").setFill()
        NSBezierPath(rect: NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)).fill()
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(hexString: "23272F").cgColor

        func configure(_ button: NSButton, symbol: String, action: Selector) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            button.contentTintColor = NSColor(white: 0.85, alpha: 1)
            addSubview(button)
        }

        configure(backButton, symbol: "chevron.backward", action: #selector(goBack))
        configure(forwardButton, symbol: "chevron.forward", action: #selector(goForward))
        configure(upButton, symbol: "arrow.up", action: #selector(goUp))

        chipStack.orientation = .horizontal
        chipStack.spacing = 2
        chipStack.alignment = .centerY
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipStack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        addSubview(chipStack)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 26),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 26),
            upButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 8),
            upButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            upButton.widthAnchor.constraint(equalToConstant: 26),
            chipStack.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 10),
            chipStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            chipStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func goBack() { onBack?() }
    @objc private func goForward() { onForward?() }
    @objc private func goUp() { onUp?() }

    @objc private func chipClicked(_ sender: NSButton) { onSelect?(UInt32(sender.tag)) }

    func update(path: [(id: UInt32, name: String)], canGoBack: Bool, canGoForward: Bool, canGoUp: Bool) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        upButton.isEnabled = canGoUp

        for view in chipStack.arrangedSubviews {
            chipStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (position, entry) in path.enumerated() {
            if position > 0 {
                let separator = NSTextField(labelWithString: "›")
                separator.textColor = NSColor(white: 0.45, alpha: 1)
                separator.font = .systemFont(ofSize: 12)
                chipStack.addArrangedSubview(separator)
            }

            let chip = NSButton(
                title: entry.name.isEmpty ? "(root)" : entry.name,
                target: self,
                action: #selector(chipClicked(_:))
            )
            chip.bezelStyle = .inline
            chip.isBordered = false
            chip.tag = Int(entry.id)
            chip.font = .systemFont(ofSize: 12, weight: position == path.count - 1 ? .semibold : .regular)
            chip.contentTintColor = position == path.count - 1
                ? NSColor.white : NSColor(white: 0.68, alpha: 1)
            chipStack.addArrangedSubview(chip)
        }

        chipStack.layoutSubtreeIfNeeded()
    }
}
