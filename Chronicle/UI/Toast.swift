import SwiftUI
import Combine

// MARK: - Toast model

/// A single toast notification rendered in the bottom-right overlay.
/// Identifiable so SwiftUI's diffing can animate rows in/out cleanly.
public struct Toast: Equatable, Identifiable {
    public let id: UUID
    public let message: String
    public let kind: Kind
    public let actionLabel: String?
    public let action: (@MainActor () -> Void)?

    public enum Kind: String, Sendable {
        case info, success, warning, error
    }

    public init(
        id: UUID = UUID(),
        message: String,
        kind: Kind = .info,
        actionLabel: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) {
        self.id = id
        self.message = message
        self.kind = kind
        self.actionLabel = actionLabel
        self.action = action
    }

    public static func == (lhs: Toast, rhs: Toast) -> Bool {
        lhs.id == rhs.id
            && lhs.message == rhs.message
            && lhs.kind == rhs.kind
            && lhs.actionLabel == rhs.actionLabel
    }
}

// MARK: - Toast center

/// Central dispatcher for user-facing transient notifications. Stored as a
/// shared singleton so non-view code (e.g. watchers, export actions) can
/// post without threading an ObservableObject all the way down.
@MainActor
public final class ToastCenter: ObservableObject {
    public static let shared = ToastCenter()

    @Published public private(set) var toasts: [Toast] = []

    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    /// Post a toast. Auto-dismisses after `autoDismissAfter` seconds unless
    /// the caller provides `nil` to make it sticky (e.g. error toasts with
    /// undo actions that the user must explicitly close).
    public func post(_ toast: Toast, autoDismissAfter: TimeInterval? = 3.0) {
        // Cap the stack at 4 so successive writes don't pile up forever.
        while toasts.count >= 4 {
            dismiss(toasts[0].id)
        }
        toasts.append(toast)
        if let after = autoDismissAfter {
            let id = toast.id
            dismissTasks[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.dismiss(id)
                }
            }
        }
    }

    public func dismiss(_ id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
        toasts.removeAll { $0.id == id }
    }

    public func clearAll() {
        for t in toasts { dismissTasks[t.id]?.cancel() }
        dismissTasks.removeAll()
        toasts.removeAll()
    }

    // MARK: - Convenience posters

    public func info(_ message: String) {
        post(Toast(message: message, kind: .info))
    }

    public func success(_ message: String) {
        post(Toast(message: message, kind: .success))
    }

    public func warning(_ message: String) {
        post(Toast(message: message, kind: .warning))
    }

    public func error(_ message: String) {
        post(Toast(message: message, kind: .error), autoDismissAfter: 5.0)
    }

    /// Success toast with an "Undo" action. Auto-dismiss window is extended
    /// so the user has a reasonable chance to click it.
    public func successWithUndo(_ message: String, undo: @MainActor @escaping () -> Void) {
        post(
            Toast(message: message, kind: .success, actionLabel: "Undo", action: undo),
            autoDismissAfter: 6.0
        )
    }
}

// MARK: - ToastOverlay

/// Bottom-right toast column. Host at the root of the window hierarchy.
public struct ToastOverlay: View {
    @ObservedObject var center: ToastCenter

    public init(center: ToastCenter) {
        self.center = center
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Spacer()
            ForEach(center.toasts) { toast in
                ToastView(toast: toast)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .padding(.trailing, 18)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.easeInOut(duration: 0.22), value: center.toasts)
        .allowsHitTesting(!center.toasts.isEmpty)
    }
}

// MARK: - ToastView

private struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 12) {
            kindGlyph
            Text(toast.message)
                .font(Theme.Font.mono(size: 11, wght: 400))
                .foregroundStyle(Theme.Color.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let label = toast.actionLabel, let act = toast.action {
                Button {
                    act()
                    ToastCenter.shared.dismiss(toast.id)
                } label: {
                    Text(label)
                        .font(Theme.Font.mono(size: 11, wght: 600))
                        .foregroundStyle(Theme.Color.accent)
                }
                .buttonStyle(.plain)
            }

            Button {
                ToastCenter.shared.dismiss(toast.id)
            } label: {
                Text("×")
                    .font(Theme.Font.mono(size: 12, wght: 400))
                    .foregroundStyle(Theme.Color.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.Color.bgElev2)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 4)
        .frame(maxWidth: 360, alignment: .leading)
    }

    private var borderColor: Color {
        switch toast.kind {
        case .error:   return Theme.Color.accent
        case .warning: return Theme.Color.dirty
        case .success: return Theme.Color.live.opacity(0.5)
        case .info:    return Theme.Color.ruleStrong
        }
    }

    @ViewBuilder
    private var kindGlyph: some View {
        let glyph: String = {
            switch toast.kind {
            case .info:    return "•"
            case .success: return "✓"
            case .warning: return "⚠"
            case .error:   return "!"
            }
        }()
        let color: Color = {
            switch toast.kind {
            case .info:    return Theme.Color.textMuted
            case .success: return Theme.Color.live
            case .warning: return Theme.Color.dirty
            case .error:   return Theme.Color.accent
            }
        }()
        Text(glyph)
            .font(Theme.Font.mono(size: 12, wght: 600))
            .foregroundStyle(color)
    }
}
