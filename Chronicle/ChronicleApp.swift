import SwiftUI
import GRDB

@main
struct ChronicleApp: App {
    @State private var repository: SessionsRepository?
    @State private var terminalPref: TerminalPreference?
    @State private var bootError: String?
    @State private var menubarModel = MenubarModel()
    @State private var watcherHub: MultiProviderWatcherHub?
    @State private var providerChangeObserver: NSObjectProtocol?
    @State private var iCloudSync: ICloudSync?
    @State private var syncTimer: Timer?
    @StateObject private var sparkleUpdater = SparkleUpdater()
    @State private var showQuarantineCard: Bool = !QuarantineDetector.isDismissed()
        && QuarantineDetector.isQuarantined()

    /// User personalization (theme, accent, density). Lives at app scope so
    /// the main window, menubar, and Settings scene share one instance.
    @StateObject private var appearance = AppearanceStore.shared
    @StateObject private var syncPrefs = SyncPreferences.shared
    @StateObject private var editorPref = EditorPreferenceStore.shared

    /// Whether the menubar icon is installed in the status bar. Always on in
    /// production. Kept as a `@State` binding so Plan 09 can add a "hide
    /// the menubar icon" Settings toggle later.
    @State private var menubarInserted = true

    /// Global hotkey coordinator. Retained here so the registrations live as
    /// long as the app process does.
    @State private var hotkeys: MenubarHotkeys?

    /// Latest non-fatal message from a hotkey (e.g. "No sessions to resume").
    /// Surfaced into the main window's bootstrapWarnings if present.
    @State private var hotkeyWarnings: [String] = []

    // Launcher is pure/stateless, so we can construct one eagerly at init.
    private let launcher: any SessionLauncherProtocol = SessionLauncher()

    init() {
        // Register bundled variable fonts *before* any view resolves Font.custom().
        FontLoader.registerAll()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ZStack {
                Group {
                    if let repo = repository {
                        AppView(
                            repository: repo,
                            launcher: launcher,
                            terminalPref: terminalPref,
                            watcherHub: watcherHub
                        )
                    } else if let err = bootError {
                        VStack {
                            Text("Chronicle failed to start")
                                .font(.title2)
                            Text(err)
                                .font(.caption)
                        }
                        .padding(40)
                    } else {
                        BootstrapSplash(progress: nil, message: "Opening database")
                    }
                }

                if showQuarantineCard {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                    QuarantineCard(onDismiss: {
                        QuarantineDetector.markDismissed()
                        showQuarantineCard = false
                    })
                    .zIndex(10)
                }
            }
            .environmentObject(appearance)
            .environmentObject(syncPrefs)
            .environmentObject(editorPref)
            .environment(\.editorLauncher, EditorLauncher())
            .environment(\.densityScale, appearance.density.paddingScale)
            .preferredColorScheme(appearance.theme.defaultColorScheme)
            .id(appearance.theme)
            .task {
                await bootstrapIfNeeded()
            }
            .onDisappear {
                // Drop the NotificationCenter observer registered in
                // bootstrapIfNeeded so we don't leak the token (and the
                // closure capture of `hub`) past the window lifetime,
                // and stop any active watcher cleanly.
                if let token = providerChangeObserver {
                    NotificationCenter.default.removeObserver(token)
                    providerChangeObserver = nil
                }
                let hub = watcherHub
                Task { await hub?.stopAll() }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for updates…") {
                    sparkleUpdater.checkForUpdates()
                }
            }
        }

        // MARK: - Settings (⌘,)
        Settings {
            SettingsView(
                syncNow: { await self.syncNowAction() },
                terminalPref: terminalPref
            )
                .environmentObject(appearance)
                .environmentObject(syncPrefs)
                .environmentObject(editorPref)
        }

        // MARK: - Menubar dropdown
        //
        // MenuBarExtra with `.window` style lets us render our full SwiftUI
        // dropdown (search + sections + footer). The repository and terminal
        // preference are the same instances the main window uses; they load
        // asynchronously at startup, so we guard the content on `nil` to
        // avoid rendering an empty popover during the first few ms of launch.
        MenuBarExtra(isInserted: $menubarInserted) {
            menubarContent
        } label: {
            // Coral bordered "CL" badge matching the .chronicle-icon in the
            // mockup: 1.5px coral stroke, 4px rounded rect, condensed bold.
            Text("CL")
                .font(Theme.Font.display(size: 11, wdth: 90, wght: 700))
                .foregroundStyle(Theme.Color.accent)
                .padding(.horizontal, 4)
                .padding(.vertical, 0)
                .overlay(
                    RoundedRectangle(cornerRadius: 3.5)
                        .stroke(Theme.Color.accent, lineWidth: 1.25)
                )
        }
        .menuBarExtraStyle(.window)
    }

    /// The menubar popover's root content. Wraps MenubarView in a loading
    /// fallback so Chronicle doesn't crash/empty-render if the DB hasn't
    /// finished opening by the time the user clicks the menubar icon.
    @ViewBuilder
    private var menubarContent: some View {
        Group {
            if let repo = repository {
                MenubarView()
                    .environment(menubarModel)
                    .environment(\.sessionLauncher, launcher)
                    .environment(\.terminalPreference, terminalPref)
                    .environment(\.sessionsRepository, repo)
                    .frame(width: 480)
                    .task(id: menubarInserted) {
                        // Re-hydrate on every open so the menubar shows the
                        // freshest live/recent sessions. Cheap: three SQL
                        // reads against the already-open database.
                        await menubarModel.reload(from: repo)
                    }
                    .environmentObject(appearance)
            } else {
                VStack(spacing: 8) {
                    Text("Chronicle is starting…")
                        .font(Theme.Font.mono(size: 11, wght: 400))
                        .foregroundStyle(Theme.Color.textMuted)
                    if let err = bootError {
                        Text(err)
                            .font(Theme.Font.mono(size: 10, wght: 400))
                            .foregroundStyle(Theme.Color.accent)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(width: 240, height: 80)
                .background(Theme.Color.bg)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Opens the DB, builds the repository + terminal preference, and runs
    /// initial migrations. Safe to call multiple times; only the first run
    /// does real work.
    private func bootstrapIfNeeded() async {
        guard repository == nil, bootError == nil else { return }
        do {
            let dbq = try Database.openDefault()
            let projectsRoot = URL(fileURLWithPath: NSString(string: "~/.claude/projects").expandingTildeInPath, isDirectory: true)
            let fts = FtsIndex(database: dbq, projectsRoot: projectsRoot)
            let repo = SessionsRepository(
                database: dbq,
                parser: JsonlParser(),
                decoder: WorkspacePathDecoder(),
                ftsIndex: fts,
                projectsRoot: projectsRoot
            )
            self.repository = repo
            self.terminalPref = TerminalPreference(database: dbq)
            installHotkeys(repository: repo)

            // Configure iCloud sync (file-based, not CloudKit).
            let sync = ICloudSync(repository: repo,
                                   containerURL: ICloudSync.defaultContainerURL())
            self.iCloudSync = sync
            if syncPrefs.enabled {
                Task.detached { @MainActor in
                    await reconcileSyncOnBootstrap()
                }
                startSyncTimer()
            }

            // Start filesystem + live-process watchers. AppView owns the
            // actual AppState instance, so the concrete handlers are wired
            // in AppView.onAppear; here we just build the hub so both
            // views share the same per-provider watcher set. The hub
            // owns one watcher per available provider and only runs the
            // active one; a chronicleActiveProviderChanged notification
            // swaps watchers without restarting the app.
            let hub = MultiProviderWatcherHub(
                repository: repo,
                projectsRoot: projectsRoot
            )
            let registry = ProviderRegistry(candidates: [
                ClaudeProvider(),
                CodexProvider(),
                GeminiProvider(),
            ])
            let availableIDs = await registry.availableIDs()
            hub.build(available: availableIDs)
            // Read the persisted active provider before starting so we
            // don't thrash on an init-time UserDefaults round-trip mid
            // bootstrap. AppState.loadActiveProviderFromDefaults() will
            // set state.activeProvider from the same key in AppView's
            // .task; replicate the read here so the initial hub start
            // matches whichever provider the segmented control will end
            // up showing.
            let persisted: ProviderID = {
                let raw = UserDefaults.standard.string(
                    forKey: AppState.activeProviderDefaultsKey
                )
                return ProviderID(rawValue: raw ?? "") ?? .claude
            }()
            let initialActive: ProviderID = availableIDs.contains(persisted) ? persisted : .claude
            await hub.setActive(initialActive)
            self.watcherHub = hub

            // Observe provider-change notifications so the hub swaps
            // watchers without app restart. AppState.switchTo posts this
            // after flipping the repo scope (Phase 2 fix), so by the
            // time we observe it the indexer is already pointed at the
            // new provider.
            let token = NotificationCenter.default.addObserver(
                forName: .chronicleActiveProviderChanged,
                object: nil,
                queue: .main
            ) { note in
                guard let raw = note.userInfo?["providerID"] as? String,
                      let id = ProviderID(rawValue: raw) else { return }
                Task { @MainActor in
                    await hub.setActive(id)
                }
            }
            self.providerChangeObserver = token

            // Fire-and-forget: purge user_metadata / sessions_index rows for
            // sessions the user soft-deleted more than 30 days ago. The file
            // itself is in ~/.Trash; macOS manages its retention separately.
            // Errors here are non-fatal; we log via the unified log facade.
            Task.detached {
                do {
                    try await repo.hardPurgeExpiredDeletes(olderThan: 30)
                } catch {
                    AppLogger.app.warn(
                        "Could not purge expired deletes: \(error.localizedDescription)"
                    )
                }
            }
        } catch {
            self.bootError = error.localizedDescription
        }
    }

    // MARK: - iCloud sync glue

    /// Pull-then-push on first launch, recording success/failure into prefs.
    @MainActor
    private func reconcileSyncOnBootstrap() async {
        guard let sync = iCloudSync else { return }
        do {
            try await sync.reconcileOnBootstrap()
            syncPrefs.recordSuccess()
        } catch {
            AppLogger.sync.warn("bootstrap reconcile failed: \(error.localizedDescription)")
            syncPrefs.recordFailure(error.localizedDescription)
        }
    }

    /// Hourly background push so a workstation doesn't have to relaunch to
    /// propagate local changes. Pull stays bootstrap-only; remote pickups
    /// don't need to be real time for a metadata-only store.
    @MainActor
    private func startSyncTimer() {
        syncTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in
                await periodicSyncPush()
            }
        }
        self.syncTimer = timer
    }

    @MainActor
    private func periodicSyncPush() async {
        guard let sync = iCloudSync, syncPrefs.enabled else { return }
        do {
            try await sync.push()
            syncPrefs.recordSuccess()
        } catch {
            syncPrefs.recordFailure(error.localizedDescription)
        }
    }

    /// Runs when the user clicks "Sync now" in Settings. Does a pull + push
    /// round-trip so the remote and local ends are fully reconciled.
    @MainActor
    private func syncNowAction() async {
        guard let sync = iCloudSync else { return }
        do {
            try await sync.pull()
            try await sync.push()
            syncPrefs.recordSuccess()
        } catch {
            syncPrefs.recordFailure(error.localizedDescription)
        }
    }

    /// Pre-bootstrap splash card. Shown while the DB is opening and the
    /// repository hasn't been created yet; replaced by the main window
    /// the moment `repository != nil`. Matches the Theme palette so the
    /// first thing the user sees isn't a generic "Starting…" string.
    struct BootstrapSplash: View {
        let progress: Double?
        let message: String

        @State private var dotsTick: Int = 0

        var body: some View {
            VStack(spacing: 18) {
                Text("CL")
                    .font(Theme.Font.display(size: 54, wdth: 90, wght: 700))
                    .foregroundStyle(Theme.Color.accent)
                    .kerning(-2.0)

                VStack(spacing: 6) {
                    Text("Indexing your sessions\(dots)")
                        .font(Theme.Font.body(size: 15, wght: 500))
                        .foregroundStyle(Theme.Color.text)
                    Text(message.isEmpty ? "Reading ~/.claude/projects" : message)
                        .font(Theme.Font.mono(size: 11, wght: 400))
                        .foregroundStyle(Theme.Color.textMuted)
                }

                if let p = progress, p > 0 {
                    progressBar(fraction: p)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(Theme.Color.accent)
                }
            }
            .frame(minWidth: 1320, minHeight: 820)
            .background(Theme.Color.bg)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    await MainActor.run { dotsTick = (dotsTick + 1) % 4 }
                }
            }
        }

        private var dots: String {
            String(repeating: ".", count: dotsTick)
        }

        private func progressBar(fraction: Double) -> some View {
            let clamped = max(0, min(1, fraction))
            return GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.Color.bgElev)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.Color.accent)
                        .frame(width: geo.size.width * clamped)
                }
            }
            .frame(width: 260, height: 6)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.Color.ruleStrong, lineWidth: 1)
            }
        }
    }

    /// Register the two app-global hotkeys. Safe to call before the
    /// menubar content itself has rendered; we just enqueue work onto the
    /// main actor and rely on `@State` bindings to deliver the effect.
    private func installHotkeys(repository: any SessionsRepositoryProtocol) {
        guard hotkeys == nil else { return }
        let hk = MenubarHotkeys(
            repository: repository,
            launcher: launcher,
            onToggleMenubar: {
                // Best-effort: try the AppKit status-item click trick first.
                // If that fails (e.g. MenuBarExtra internal API changed in a
                // future macOS), fall back to toggling isInserted so at
                // least the user gets some visible feedback.
                if !MenubarExtraOpener.openProgrammatically() {
                    // Flicker toggle: at minimum signals the shortcut was heard.
                    menubarInserted = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        menubarInserted = true
                    }
                }
            },
            onError: { msg in
                hotkeyWarnings.append(msg)
            }
        )
        hk.registerAll()
        self.hotkeys = hk
    }
}
