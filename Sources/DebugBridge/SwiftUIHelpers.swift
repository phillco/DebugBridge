#if canImport(SwiftUI)
import SwiftUI

// MARK: - Make SwiftUI views controllable via DebugBridge

public extension View {
    /// Makes this view tappable via DebugBridge by setting an accessibility identifier
    /// and ensuring accessibility activation triggers the action.
    ///
    /// Usage:
    /// ```swift
    /// Button("Refresh") { refresh() }
    ///     .debugTappable("refresh-button")
    ///
    /// // Can now tap via: POST /tap {"id": "refresh-button"}
    /// ```
    func debugTappable(_ identifier: String) -> some View {
        self
            .accessibilityIdentifier(identifier)
            .accessibilityAddTraits(.isButton)
    }

    /// Makes this view tappable and registers a custom action that will be triggered
    /// when the element is activated via DebugBridge.
    ///
    /// Usage:
    /// ```swift
    /// SessionRow(session: session)
    ///     .debugAction("session-\(session.id)") {
    ///         selectedSession = session
    ///     }
    /// ```
    func debugAction(_ identifier: String, action: @escaping () -> Void) -> some View {
        self
            .accessibilityIdentifier(identifier)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) {
                action()
            }
    }
}

// MARK: - Scriptable Navigation

/// A NavigationLink wrapper that works with DebugBridge
///
/// Usage:
/// ```swift
/// ScriptableNavigationLink("session-\(session.pane)", destination: ChatView(session: session)) {
///     SessionRow(session: session)
/// }
/// ```
public struct ScriptableNavigationLink<Label: View, Destination: View>: View {
    let identifier: String
    let destination: Destination
    let label: Label

    public init(_ identifier: String, destination: Destination, @ViewBuilder label: () -> Label) {
        self.identifier = identifier
        self.destination = destination
        self.label = label()
    }

    public var body: some View {
        NavigationLink(destination: destination) {
            label
        }
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Scriptable List

/// A List row wrapper that makes the row accessible to DebugBridge
public struct ScriptableRow<Content: View>: View {
    let identifier: String
    let content: Content
    let onSelect: (() -> Void)?

    public init(_ identifier: String, onSelect: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.identifier = identifier
        self.onSelect = onSelect
        self.content = content()
    }

    public var body: some View {
        content
            .accessibilityIdentifier(identifier)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) {
                onSelect?()
            }
    }
}
#endif
