import AppKit

/// A small always-on-top panel for the answer. It hides itself `hideAfter` seconds after an answer,
/// so an old answer isn't left on screen (or in the next screenshot).
/// Unlike Cluely's overlay, it is visible in screen shares and recordings: sharingType is left at its default.
final class AnswerPanel {
    static let width: CGFloat = 460
    static let margin: CGFloat = 24
    static let inset: CGFloat = 14
    /// Long answers (code) scroll instead of running off the screen.
    static let maxScreenFraction: CGFloat = 0.7

    private let panel: NSPanel
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private var hideTimer: Timer?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "cluely-local"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 14)
        text.textContainerInset = NSSize(width: Self.inset, height: Self.inset)
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        panel.contentView = scroll
    }

    var window: NSWindow { panel }

    /// Call on the main thread.
    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel.orderOut(nil)
    }

    /// Shows `message`. With `hideAfter`, hides it that many seconds later unless something newer is shown.
    /// Call on the main thread.
    func show(_ message: String, hideAfter: TimeInterval? = nil) {
        hideTimer?.invalidate()
        hideTimer = nil
        // Code reads better in a fixed-width font.
        text.font = message.contains("```") || message.contains("    ")
            ? .monospacedSystemFont(ofSize: 12.5, weight: .regular) : .systemFont(ofSize: 14)
        text.string = message

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        text.frame.size.width = Self.width
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let used = text.layoutManager?.usedRect(for: text.textContainer!).height ?? 80
        let height = min(used + Self.inset * 2, screen.height * Self.maxScreenFraction)
        panel.setContentSize(NSSize(width: Self.width, height: height))
        panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - Self.margin, y: screen.maxY - Self.margin))
        text.scrollToBeginningOfDocument(nil)
        panel.orderFrontRegardless()

        if let hideAfter {
            hideTimer = Timer.scheduledTimer(withTimeInterval: hideAfter, repeats: false) { [weak self] _ in
                self?.panel.orderOut(nil)
            }
        }
    }
}
