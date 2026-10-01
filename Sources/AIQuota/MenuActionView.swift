import AppKit

/// An embedded native button handles clicks without ending NSMenu tracking.
/// Standard items remain responsible for Settings, Restart and Quit semantics.
@MainActor
final class MenuActionView: NSView {
    private let button = NSButton()
    private let action: () -> Void

    init(title: String, width: CGFloat, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        autoresizingMask = [.width]
        button.frame = bounds.insetBy(dx: 16, dy: 0)
        button.autoresizingMask = [.width, .height]
        button.isBordered = false
        button.alignment = .left
        button.font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        button.setButtonType(.momentaryChange)
        button.target = self
        button.action = #selector(activate)
        addSubview(button)
        update(title: title, enabled: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(title: String, enabled: Bool) {
        button.title = title
        button.isEnabled = enabled
        button.setAccessibilityLabel(title)
    }

    @objc private func activate() { action() }
}
