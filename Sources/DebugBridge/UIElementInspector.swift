#if canImport(UIKit)
import UIKit

/// Represents an interactive UI element
public struct UIElementInfo: Codable {
    public let id: String           // Unique identifier for this element
    public let label: String?       // Accessibility label or button title
    public let type: String         // button, textfield, toggle, cell, etc.
    public let value: String?       // Current value (toggle state, text content)
    public let enabled: Bool
    public let frame: FrameInfo
    public let traits: [String]     // Accessibility traits

    public struct FrameInfo: Codable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }
}

/// Inspects and interacts with UI elements
@MainActor
public final class UIElementInspector {
    public static let shared = UIElementInspector()

    private init() {}

    /// Get all interactive elements on screen
    public func getElements() -> [UIElementInfo] {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            return []
        }

        var elements: [UIElementInfo] = []
        var index = 0

        collectElements(from: window, into: &elements, index: &index)

        return elements
    }

    private func collectElements(from view: UIView, into elements: inout [UIElementInfo], index: inout Int, depth: Int = 0) {
        // Skip hidden views
        guard !view.isHidden && view.alpha > 0 else { return }

        // Check if this view is interactive
        if let element = inspectElement(view, index: index) {
            elements.append(element)
            index += 1
        }

        // Recurse into subviews
        for subview in view.subviews {
            collectElements(from: subview, into: &elements, index: &index, depth: depth + 1)
        }
    }

    private func inspectElement(_ view: UIView, index: Int) -> UIElementInfo? {
        let type = elementType(for: view)

        // Include if: has an explicit accessibility identifier, is interactive, or is an accessibility element
        let hasExplicitId = view.accessibilityIdentifier != nil && !view.accessibilityIdentifier!.isEmpty
        guard type != nil || view.isAccessibilityElement || hasExplicitId else { return nil }

        let elementType = type ?? "element"
        let label = view.accessibilityLabel ?? buttonTitle(for: view)
        let id = view.accessibilityIdentifier ?? "\(elementType)_\(index)"

        // Get screen coordinates
        let frameInWindow = view.convert(view.bounds, to: nil)

        return UIElementInfo(
            id: id,
            label: label,
            type: elementType,
            value: elementValue(for: view),
            enabled: view.isUserInteractionEnabled && (view as? UIControl)?.isEnabled ?? true,
            frame: UIElementInfo.FrameInfo(
                x: Double(frameInWindow.origin.x),
                y: Double(frameInWindow.origin.y),
                width: Double(frameInWindow.size.width),
                height: Double(frameInWindow.size.height)
            ),
            traits: accessibilityTraits(for: view)
        )
    }

    private func elementType(for view: UIView) -> String? {
        // Check specific types first
        if view is UIButton { return "button" }
        if view is UISwitch { return "switch" }
        if view is UITextField { return "textfield" }
        if view is UITextView { return "textview" }
        if view is UISlider { return "slider" }
        if view is UISegmentedControl { return "segmented" }
        if view is UIStepper { return "stepper" }
        if view is UIDatePicker { return "datepicker" }
        if view is UIPickerView { return "picker" }

        // Check for table/collection view cells
        if view is UITableViewCell { return "cell" }
        if view is UICollectionViewCell { return "cell" }

        // Check for tap gesture recognizers (common in SwiftUI)
        if let gestures = view.gestureRecognizers {
            let hasTapGesture = gestures.contains { $0 is UITapGestureRecognizer && $0.isEnabled }
            if hasTapGesture { return "tappable" }
        }

        // Check accessibility traits
        let traits = view.accessibilityTraits
        if traits.contains(.button) { return "button" }
        if traits.contains(.link) { return "link" }
        if traits.contains(.searchField) { return "searchfield" }
        if traits.contains(.adjustable) { return "adjustable" }

        return nil
    }

    private func buttonTitle(for view: UIView) -> String? {
        if let button = view as? UIButton {
            return button.currentTitle ?? button.titleLabel?.text
        }
        if let cell = view as? UITableViewCell {
            return cell.textLabel?.text
        }
        return nil
    }

    private func elementValue(for view: UIView) -> String? {
        if let toggle = view as? UISwitch {
            return toggle.isOn ? "on" : "off"
        }
        if let textField = view as? UITextField {
            return textField.text
        }
        if let textView = view as? UITextView {
            return textView.text
        }
        if let slider = view as? UISlider {
            return String(format: "%.2f", slider.value)
        }
        if let segment = view as? UISegmentedControl {
            return segment.titleForSegment(at: segment.selectedSegmentIndex)
        }
        return view.accessibilityValue
    }

    private func accessibilityTraits(for view: UIView) -> [String] {
        var traits: [String] = []
        let t = view.accessibilityTraits

        if t.contains(.button) { traits.append("button") }
        if t.contains(.link) { traits.append("link") }
        if t.contains(.image) { traits.append("image") }
        if t.contains(.selected) { traits.append("selected") }
        if t.contains(.playsSound) { traits.append("playsSound") }
        if t.contains(.keyboardKey) { traits.append("keyboardKey") }
        if t.contains(.staticText) { traits.append("staticText") }
        if t.contains(.summaryElement) { traits.append("summaryElement") }
        if t.contains(.notEnabled) { traits.append("notEnabled") }
        if t.contains(.updatesFrequently) { traits.append("updatesFrequently") }
        if t.contains(.searchField) { traits.append("searchField") }
        if t.contains(.startsMediaSession) { traits.append("startsMediaSession") }
        if t.contains(.adjustable) { traits.append("adjustable") }
        if t.contains(.allowsDirectInteraction) { traits.append("allowsDirectInteraction") }
        if t.contains(.causesPageTurn) { traits.append("causesPageTurn") }
        if t.contains(.header) { traits.append("header") }
        if t.contains(.tabBar) { traits.append("tabBar") }

        return traits
    }

    // MARK: - Interaction

    /// Tap an element by ID or label
    /// Returns true if element was found and tapped
    public func tap(identifier: String) -> Bool {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            return false
        }

        // Check if identifier is a generated ID like "cell_3" or "button_5"
        if let (type, index) = parseGeneratedId(identifier) {
            return findAndTapByTypeIndex(in: window, type: type, targetIndex: index)
        }

        return findAndTap(in: window, identifier: identifier)
    }

    /// Parse generated IDs like "cell_3", "button_5", "tappable_0"
    private func parseGeneratedId(_ identifier: String) -> (type: String, index: Int)? {
        let parts = identifier.split(separator: "_")
        guard parts.count == 2,
              let index = Int(parts[1]) else {
            return nil
        }
        return (String(parts[0]), index)
    }

    /// Find and tap the Nth element of a given type
    private func findAndTapByTypeIndex(in window: UIView, type: String, targetIndex: Int) -> Bool {
        var currentIndex = 0
        return findElementByTypeIndex(in: window, type: type, targetIndex: targetIndex, currentIndex: &currentIndex)
    }

    private func findElementByTypeIndex(in view: UIView, type: String, targetIndex: Int, currentIndex: inout Int) -> Bool {
        guard !view.isHidden && view.alpha > 0 else { return false }

        // Check if this view matches the type
        if let viewType = elementType(for: view), viewType == type {
            if currentIndex == targetIndex {
                return performTap(on: view)
            }
            currentIndex += 1
        }

        // Recurse into subviews
        for subview in view.subviews {
            if findElementByTypeIndex(in: subview, type: type, targetIndex: targetIndex, currentIndex: &currentIndex) {
                return true
            }
        }

        return false
    }

    private func findAndTap(in view: UIView, identifier: String) -> Bool {
        // Check if this view matches
        if matches(view, identifier: identifier) {
            return performTap(on: view)
        }

        // Recurse into subviews
        for subview in view.subviews {
            if findAndTap(in: subview, identifier: identifier) {
                return true
            }
        }

        return false
    }

    private func matches(_ view: UIView, identifier: String) -> Bool {
        // Match by accessibility identifier
        if view.accessibilityIdentifier == identifier {
            return true
        }

        // Match by accessibility label (case insensitive)
        if let label = view.accessibilityLabel, label.localizedCaseInsensitiveCompare(identifier) == .orderedSame {
            return true
        }

        // Match button title
        if let button = view as? UIButton,
           let title = button.currentTitle,
           title.localizedCaseInsensitiveCompare(identifier) == .orderedSame {
            return true
        }

        // Match cell text
        if let cell = view as? UITableViewCell,
           let text = cell.textLabel?.text,
           text.localizedCaseInsensitiveCompare(identifier) == .orderedSame {
            return true
        }

        return false
    }

    private func performTap(on view: UIView) -> Bool {
        // Method 1: UIControl sendActions (UIKit buttons)
        if let control = view as? UIControl {
            control.sendActions(for: .touchUpInside)
            return true
        }

        // Method 2: Try accessibility activate (works for many SwiftUI views)
        if view.accessibilityActivate() {
            return true
        }

        // Method 3: Find and trigger tap gesture recognizers
        if triggerTapGesture(on: view) {
            return true
        }

        // Method 4: Simulate touch events at view center
        return simulateTouch(on: view)
    }

    private func triggerTapGesture(on view: UIView) -> Bool {
        // Skip private API gesture triggering - too fragile
        // Rely on accessibility activation instead
        return false
    }

    private func simulateTouch(on view: UIView) -> Bool {
        guard let window = view.window else { return false }

        let centerInView = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let centerInWindow = view.convert(centerInView, to: window)

        // Use hit testing to find the actual responder
        if let hitView = window.hitTest(centerInWindow, with: nil) {
            // Try accessibility on the hit view
            if hitView.accessibilityActivate() {
                return true
            }

            // Try gesture recognizers on hit view
            if hitView !== view && triggerTapGesture(on: hitView) {
                return true
            }

            // Walk up responder chain looking for something tappable
            var responder: UIResponder? = hitView
            while let current = responder {
                if let currentView = current as? UIView {
                    if currentView.accessibilityActivate() {
                        return true
                    }
                    if triggerTapGesture(on: currentView) {
                        return true
                    }
                }
                responder = current.next
            }
        }

        return false
    }

    /// Scroll in the current view
    /// direction: "up", "down", "left", "right"
    /// amount: scroll distance in points (default 300)
    public func scroll(direction: String, amount: Double = 300) -> Bool {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            return false
        }

        // Find the first scroll view
        if let scrollView = findScrollView(in: window) {
            var offset = scrollView.contentOffset
            switch direction.lowercased() {
            case "up":
                offset.y = max(0, offset.y - CGFloat(amount))
            case "down":
                offset.y = min(scrollView.contentSize.height - scrollView.bounds.height, offset.y + CGFloat(amount))
            case "left":
                offset.x = max(0, offset.x - CGFloat(amount))
            case "right":
                offset.x = min(scrollView.contentSize.width - scrollView.bounds.width, offset.x + CGFloat(amount))
            default:
                return false
            }
            scrollView.setContentOffset(offset, animated: true)
            return true
        }
        return false
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView, scrollView.isScrollEnabled {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }

    /// Tap at specific screen coordinates
    public func tapAtPoint(x: Double, y: Double) -> Bool {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            return false
        }

        let point = CGPoint(x: x, y: y)

        if let hitView = window.hitTest(point, with: nil) {
            // Try accessibility first
            if hitView.accessibilityActivate() {
                return true
            }

            // Try gesture recognizers
            if triggerTapGesture(on: hitView) {
                return true
            }

            // Try UIControl
            if let control = hitView as? UIControl {
                control.sendActions(for: .touchUpInside)
                return true
            }

            // Walk up to find tappable parent
            var responder: UIResponder? = hitView.next
            while let current = responder {
                if let currentView = current as? UIView {
                    if currentView.accessibilityActivate() {
                        return true
                    }
                    if triggerTapGesture(on: currentView) {
                        return true
                    }
                }
                responder = current.next
            }
        }

        return false
    }

    /// Type text into a text field by ID or label
    public func typeText(identifier: String, text: String) -> Bool {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            return false
        }

        return findAndType(in: window, identifier: identifier, text: text)
    }

    private func findAndType(in view: UIView, identifier: String, text: String) -> Bool {
        if matches(view, identifier: identifier) {
            if let textField = view as? UITextField {
                textField.text = text
                textField.sendActions(for: .editingChanged)
                return true
            }
            if let textView = view as? UITextView {
                textView.text = text
                textView.delegate?.textViewDidChange?(textView)
                return true
            }
        }

        for subview in view.subviews {
            if findAndType(in: subview, identifier: identifier, text: text) {
                return true
            }
        }

        return false
    }

    /// Toggle a switch by ID or label
    public func toggle(identifier: String) -> Bool {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            return false
        }

        return findAndToggle(in: window, identifier: identifier)
    }

    private func findAndToggle(in view: UIView, identifier: String) -> Bool {
        if matches(view, identifier: identifier) {
            if let toggle = view as? UISwitch {
                toggle.setOn(!toggle.isOn, animated: true)
                toggle.sendActions(for: .valueChanged)
                return true
            }
        }

        for subview in view.subviews {
            if findAndToggle(in: subview, identifier: identifier) {
                return true
            }
        }

        return false
    }
}
#endif
