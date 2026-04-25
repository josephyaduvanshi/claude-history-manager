import SwiftUI

/// Personalization Settings window. Opened from `Chronicle → Settings…`
/// (`⌘,`) via the app's `Settings` scene.
///
/// Five groups (Plan 09 adds Sync + Editor):
///   1. **Appearance**. Light / Dark / Auto toggle.
///   2. **Accent**; eight preset swatches + a system ColorPicker.
///   3. **Density**. Compact / Comfortable / Spacious.
///   4. **Sync**; iCloud Drive sync toggle + Sync now + last synced.
///   5. **Editor integration**. Default editor picker + "Open in X" preview.
struct SettingsView: View {
    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var syncPrefs: SyncPreferences
    @EnvironmentObject private var editorPref: EditorPreferenceStore

    /// Injected by ChronicleApp so the "Sync now" button has something to
    /// call into. Nil = sync not configured (e.g. running in tests).
    var syncNow: (() async -> Void)? = nil

    /// Injected by ChronicleApp so the Terminal picker can read/write the
    /// machine-wide default terminal. Nil in tests / before bootstrap.
    var terminalPref: TerminalPreference? = nil

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance.theme) {
                    ForEach(ChronicleTheme.displayOrder) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Accent color") {
                AccentPicker()
            }

            Section("Density") {
                Picker("Density", selection: $appearance.density) {
                    ForEach(AppearanceStore.Density.allCases) { d in
                        Text(d.label).tag(d)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Sync") {
                SyncSection(syncNow: syncNow)
            }

            Section("Terminal") {
                TerminalSection(pref: terminalPref)
            }

            Section("Editor integration") {
                EditorSection()
            }

            Section {
                Button("Restore defaults") { appearance.resetToDefaults() }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - Accent picker

private struct AccentPicker: View {
    @EnvironmentObject private var appearance: AppearanceStore

    private var customBinding: Binding<Color> {
        Binding(
            get: { appearance.accentOverride ?? Theme.Color.accent },
            set: { newColor in
                appearance.accentHex = AppearanceStore.encodeHex(newColor)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ForEach(AppearanceStore.presets) { swatch in
                    SwatchButton(swatch: swatch,
                                 isSelected: isSelected(swatch)) {
                        appearance.accentHex = (swatch.id == "coral")
                            ? nil
                            : swatch.hex
                    }
                }
            }

            HStack(spacing: 12) {
                ColorPicker("Custom", selection: customBinding, supportsOpacity: false)
                    .labelsHidden()
                Text("Custom color")
                    .font(.body)
                Spacer()
                if appearance.accentHex != nil {
                    Button("Reset to coral") {
                        appearance.accentHex = nil
                    }
                }
            }
        }
    }

    private func isSelected(_ swatch: AppearanceStore.Swatch) -> Bool {
        if swatch.id == "coral" {
            return appearance.accentHex == nil
        }
        return appearance.accentHex?.caseInsensitiveCompare(swatch.hex) == .orderedSame
    }
}

private struct SwatchButton: View {
    let swatch: AppearanceStore.Swatch
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(swatch.color)
                .frame(width: 26, height: 26)
                .overlay(
                    Circle()
                        .stroke(isSelected ? Color.primary : Color.secondary.opacity(0.3),
                                lineWidth: isSelected ? 2 : 1)
                )
                .padding(2)
        }
        .buttonStyle(.plain)
        .help(swatch.label)
    }
}

// MARK: - Sync section

private struct SyncSection: View {
    @EnvironmentObject private var prefs: SyncPreferences
    let syncNow: (() async -> Void)?
    @State private var syncing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("iCloud Drive sync", isOn: $prefs.enabled)
                .help("""
                    Chronicle syncs pin / tag / archive metadata to \
                    ~/Library/Mobile Documents/com~apple~CloudDocs/Chronicle/.
                    Transcripts never leave this Mac.
                    """)

            HStack(spacing: 8) {
                Text("Last synced:")
                    .foregroundStyle(.secondary)
                Text(lastSyncedText)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if !prefs.lastSyncStatus.isEmpty && prefs.lastSyncStatus != "Synced" {
                    Text("· \(prefs.lastSyncStatus)")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    Task { await triggerSync() }
                } label: {
                    if syncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Sync now")
                    }
                }
                .disabled(!prefs.enabled || syncNow == nil || syncing)
            }
            .font(.callout)

            if !icloudAvailable() {
                Text("iCloud Drive isn't signed in on this Mac. Sync will stay idle.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var lastSyncedText: String {
        guard let date = prefs.lastSyncedAt else { return "never" }
        return RelativeTime.shortAgo(from: date)
    }

    private func triggerSync() async {
        guard let syncNow else { return }
        syncing = true
        await syncNow()
        syncing = false
    }

    /// Heuristic check: does the Mobile Documents folder exist and is it
    /// writable? Mirrors the runtime ICloudSync.availability() check.
    private func icloudAvailable() -> Bool {
        let url = ICloudSync.defaultContainerURL()
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // It's fine. OS will create it on first write. The parent
            // Mobile Documents path is what matters.
            let parent = url.deletingLastPathComponent()
            return fm.fileExists(atPath: parent.path)
        }
        return true
    }
}

// MARK: - Terminal section

private struct TerminalSection: View {
    let pref: TerminalPreference?

    @State private var selected: Terminal = .terminal
    @State private var installed: [Terminal] = Terminal.allCases
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Default terminal", selection: $selected) {
                ForEach(installed) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: selected) { _, new in
                guard loaded, let pref else { return }
                Task { await pref.setDefaultTerminal(new) }
            }

            Text("""
                The "Resume in {Terminal}" button and the menubar's launch \
                shortcut both use this terminal. Per-session overrides set \
                via the launch picker take precedence.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            installed = Terminal.installed()
            if installed.isEmpty { installed = Terminal.allCases }
            if let pref {
                let current = await pref.defaultTerminal()
                selected = installed.contains(current) ? current : (installed.first ?? .terminal)
            }
            loaded = true
        }
    }
}

// MARK: - Editor section

private struct EditorSection: View {
    @EnvironmentObject private var store: EditorPreferenceStore

    /// Sentinel for "None (hide the button)".
    private enum Selection: Hashable {
        case none_
        case editor(Editor)
    }

    private var selection: Binding<Selection> {
        Binding(
            get: {
                if let ed = store.editor { return .editor(ed) }
                return .none_
            },
            set: { newValue in
                switch newValue {
                case .none_:            store.editor = nil
                case .editor(let ed):   store.editor = ed
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Default editor", selection: selection) {
                Text("None").tag(Selection.none_)
                ForEach(Editor.allCases) { editor in
                    Text(editor.displayName).tag(Selection.editor(editor))
                }
            }
            .pickerStyle(.menu)

            Text("""
                When set, Chronicle shows an "Open in {Editor}" button on \
                session preview + transcript views. Launches via `open -a` \
                when the desktop app is installed, otherwise falls back to \
                the matching CLI shim.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
