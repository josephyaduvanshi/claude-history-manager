import SwiftUI
import AppKit
import Foundation

// MARK: - Detector

/// Checks whether the current `.app` bundle is still flagged with the macOS
/// `com.apple.quarantine` extended attribute. Sandbox-signed apps always
/// return false because the xattr is cleared by the OS at launch.
public enum QuarantineDetector {
    public static let fixCommand = "xattr -cr /Applications/Chronicle.app"
    public static let dismissalKey = "chronicle.quarantineDismissed"

    /// True when the bundle path carries the quarantine xattr. On dev
    /// builds launched via `swift run` this is generally false.
    public static func isQuarantined(at bundlePath: String = Bundle.main.bundlePath) -> Bool {
        return hasExtendedAttribute(path: bundlePath, name: "com.apple.quarantine")
    }

    /// True when the user previously dismissed the card. Persisted so the
    /// card doesn't re-appear every launch.
    public static func isDismissed(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: dismissalKey)
    }

    public static func markDismissed(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: dismissalKey)
    }

    public static func resetDismissal(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: dismissalKey)
    }

    /// Read an extended attribute via `getxattr(2)`. Returns true iff the
    /// attribute exists and has at least one byte of data. Safe to call on
    /// any path; returns false for missing files or missing attrs.
    static func hasExtendedAttribute(path: String, name: String) -> Bool {
        return path.withCString { pathC in
            name.withCString { nameC in
                // Passing nil buffer with size 0 returns the actual length;
                // getxattr returns -1 and sets errno when the attr is absent.
                let sz = getxattr(pathC, nameC, nil, 0, 0, 0)
                return sz > 0
            }
        }
    }
}

// MARK: - Card

struct QuarantineCard: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.Color.rule).frame(height: 1)
            body_
            Rectangle().fill(Theme.Color.rule).frame(height: 1)
            footer
        }
        .frame(width: 520)
        .background(Theme.Color.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.Color.ruleStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GATEKEEPER")
                .font(Theme.Font.mono(size: 10.5, wght: 600))
                .foregroundStyle(Theme.Color.accent)
                .kerning(1.6)
            Text("macOS quarantined Chronicle")
                .font(Theme.Font.display(size: 18, wght: 600))
                .foregroundStyle(Theme.Color.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("""
                Chronicle ships ad-hoc signed because we can't afford \
                Apple's $99/year notarization tax. Gatekeeper flagged \
                the bundle with `com.apple.quarantine` when you downloaded it.
                """)
                .font(Theme.Font.body(size: 13, wght: 400))
                .foregroundStyle(Theme.Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Text("Open Terminal and run this one-liner, then relaunch:")
                .font(Theme.Font.body(size: 13, wght: 500))
                .foregroundStyle(Theme.Color.text)

            commandBox
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @State private var copied = false

    private var commandBox: some View {
        HStack(spacing: 10) {
            Text(QuarantineDetector.fixCommand)
                .font(Theme.Font.mono(size: 12, wght: 500))
                .foregroundStyle(Theme.Color.text)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Color.bg)

            Button(action: copyCommand) {
                Text(copied ? "Copied" : "Copy")
                    .font(Theme.Font.mono(size: 11, wght: 600))
                    .foregroundStyle(copied ? Theme.Color.onAccent : Theme.Color.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(copied ? Theme.Color.accent : Theme.Color.bgElev2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(copied ? Color.clear : Theme.Color.ruleStrong, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.Color.ruleStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack {
            Text("You'll only see this message once.")
                .font(Theme.Font.mono(size: 10.5, wght: 400))
                .foregroundStyle(Theme.Color.textDim)
            Spacer()
            Button(action: onDismiss) {
                Text("Dismiss")
                    .font(Theme.Font.mono(size: 11, wght: 600))
                    .foregroundStyle(Theme.Color.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.Color.bgElev2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Theme.Color.ruleStrong, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(QuarantineDetector.fixCommand, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            copied = false
        }
    }
}
