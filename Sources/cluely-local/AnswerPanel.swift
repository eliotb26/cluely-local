import AppKit

/// A small always-on-top panel for the answer.
/// Unlike Cluely's overlay, it is visible in screen shares and recordings: sharingType is left at its default.
final class AnswerPanel {
    static let width: CGFloat = 420
    static let margin: CGFloat = 24

    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "cluely-local"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        label.font = .systemFont(ofSize: 14)
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            label.widthAnchor.constraint(equalToConstant: Self.width - 32),
        ])
        panel.contentView = content
    }

    var window: NSWindow { panel }

    /// Call on the main thread.
    func show(_ text: String) {
        label.stringValue = text
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: Self.width, height: 120))
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - Self.margin,
                                               y: screen.maxY - Self.margin))
        }
        panel.orderFrontRegardless()
    }
}
