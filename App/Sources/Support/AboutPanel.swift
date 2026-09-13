import AppKit
import InventoryIndex

/// The standard About panel, filled in with the app's own description and credits.
enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "S3 Inventory Visualizer",
            .credits: credits(),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "Copyright 2026 Guiware LLC",
        ])
    }

    private static func credits() -> NSAttributedString {
        let text = NSMutableAttributedString()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 9

        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let quiet: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let emphasis: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]

        // The panel clips a long credits string, so this stays to five short blocks.
        text.append(NSAttributedString(
            string: "A treemap visualizer for S3 Inventory exports.\n",
            attributes: body
        ))
        text.append(NSAttributedString(
            string: "Built to scale to billions of objects and more.\n",
            attributes: quiet
        ))

        // text.append(NSAttributedString(string: "Guiware LLC\n", attributes: emphasis))

        let link = NSMutableAttributedString(string: "guipinto.com\n", attributes: quiet)
        link.addAttribute(
            .link,
            value: URL(string: "https://guipinto.com")!,
            range: NSRange(location: 0, length: "guipinto.com".count)
        )
        text.append(link)

        return text
    }
}
