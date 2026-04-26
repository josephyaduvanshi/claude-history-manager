<h1 align="center">
  <br>
  <a href="https://github.com/josephyaduvanshi/claude-history-manager">
    <img src="docs/branding/icon-1024.png" alt="Chronicle" width="180">
  </a>
  <br>
  Chronicle
  <br>
</h1>

<p align="center">
  <strong>A native macOS browser for your CLI coding-assistant session history — <a href="https://claude.com/claude-code" target="_blank">Claude Code</a>, <a href="https://github.com/openai/codex" target="_blank">Codex CLI</a>, and <a href="https://github.com/google-gemini/gemini-cli" target="_blank">Gemini CLI</a>.</strong><br/>
  Reads each provider's session storage directly. Per-provider data isolation. Indexes everything into local SQLite. Resumes any session in one keystroke.
</p>

<p align="center">
  <a href="https://github.com/josephyaduvanshi/claude-history-manager/releases">
    <img src="https://img.shields.io/github/v/release/josephyaduvanshi/claude-history-manager?style=flat-square&color=8A2BE2&include_prereleases" alt="Release" />
  </a>
  <a href="https://github.com/josephyaduvanshi/claude-history-manager/blob/main/LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License" />
  </a>
  <img src="https://img.shields.io/badge/macOS-15.0%2B-black?style=flat-square&logo=apple&logoColor=white" alt="macOS 15.0+" />
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.0" />
  <img src="https://img.shields.io/badge/SwiftUI-native-1F7AE0?style=flat-square" alt="SwiftUI" />
  <img src="https://img.shields.io/badge/SQLite-FTS5-003B57?style=flat-square&logo=sqlite&logoColor=white" alt="SQLite FTS5" />
</p>

<p align="center">
  <a href="https://github.com/josephyaduvanshi"><img src="https://img.shields.io/github/followers/josephyaduvanshi.svg?style=social&label=Follow" alt="Follow"/></a>
  <a href="https://twitter.com/Josefyaduvanshi"><img src="https://img.shields.io/twitter/follow/Josefyaduvanshi.svg?style=social" alt="Twitter Follow"/></a>
</p>

<p align="center">
  <em>If this saves you from grepping JSONL files at 1am, star the repo. Thanks.</em>
</p>

<p align="center">
  <a href="#install">Install</a> •
  <a href="#linux-cli">Linux CLI</a> •
  <a href="#first-launch-on-macos">First launch</a> •
  <a href="#how-it-works">How it works</a> •
  <a href="#features">Features</a> •
  <a href="#privacy">Privacy</a> •
  <a href="#keyboard-shortcuts">Shortcuts</a> •
  <a href="#configuration">Configuration</a> •
  <a href="#faq">FAQ</a> •
  <a href="#license">License</a>
</p>

---

Three CLI coding assistants, three different transcript formats, all sitting in different corners of your home directory. Claude Code writes JSONL under `~/.claude/projects/`. Codex CLI writes JSONL under `~/.codex/sessions/`. Gemini CLI writes single JSON files under `~/.gemini/tmp/`. After a few weeks of real use, those folders are unreadable, ungreppable, and the only way to find the session where you actually solved that one bug is to remember which workspace you were in and scroll through `ls -lt`. Chronicle reads all three, indexes every session into a local SQLite database, and gives you somewhere to actually look at them. Per-provider data isolation: switching providers swaps every list, count, and stat, so a Claude pin doesn't leak into your Codex sidebar. Pin the ones that matter. Tag the ones you're tracking. Resume any of them in one keystroke, in whichever terminal you prefer.

Transcripts never leave the Mac they were written on.

<p align="center">
  <img src="docs/branding/screenshots/01-main.png" alt="Chronicle main window" width="900">
</p>

---

## Install

### Homebrew (recommended)

```bash
brew tap josephyaduvanshi/chronicle
brew install --cask chronicle
```

The cask handles the download, the drag into `/Applications`, and the Gatekeeper unquarantine step in one go. To update later:

```bash
brew update                              # refreshes the tap; the tap auto-bumps on every release
brew upgrade --cask chronicle
```

If you previously installed Chronicle by dragging the `.app` manually and now want Homebrew to take over, add `--force`:

```bash
brew install --cask chronicle --force    # overwrites the manual install + registers it with brew
```

If `brew install` reports a 404 on the DMG, your local tap cache is stale — run `brew update` first.

Tap source: [josephyaduvanshi/homebrew-chronicle](https://github.com/josephyaduvanshi/homebrew-chronicle).

### Installer (.pkg)

For the lowest-friction install without Homebrew. Download `Chronicle-<version>.pkg` from the latest [GitHub Release](https://github.com/josephyaduvanshi/claude-history-manager/releases), double-click, follow the prompts. The installer drops `Chronicle.app` in `/Applications/` and strips the Gatekeeper quarantine via a postinstall script. macOS will warn that the package isn't signed by an identified developer; right-click the `.pkg` and choose Open the first time.

### Disk image (.dmg)

Download `Chronicle-<version>.dmg` from the [release page](https://github.com/josephyaduvanshi/claude-history-manager/releases), mount it, drag `Chronicle.app` onto the Applications shortcut, then run:

```bash
xattr -cr /Applications/Chronicle.app
```

### Download the .zip

1. Grab `Chronicle-<version>.zip` from the latest [GitHub Release](https://github.com/josephyaduvanshi/claude-history-manager/releases).
2. Unzip and drag `Chronicle.app` into `/Applications/`.
3. Strip the Gatekeeper quarantine attribute so macOS will launch the ad-hoc-signed binary:

   ```bash
   xattr -cr /Applications/Chronicle.app
   ```

4. Open Chronicle. The first launch indexes `~/.claude/projects/` (about 60 to 90 seconds for a few thousand sessions). If the sidebar stays empty, grant Full Disk Access in `System Settings` > `Privacy & Security` > `Full Disk Access` and relaunch.

If you skip the `xattr` step, Chronicle still launches but shows an in-app card with the same one-liner and a copy-to-clipboard button.

> [!NOTE]
> Chronicle is ad-hoc signed, not notarized. Apple notarization needs a paid Developer ID ($99/year) which this project doesn't carry yet. The binary you download is bit-for-bit what the GitHub Actions workflow builds from `main`, and the release page lists the SHA256 if you want to verify. See [First launch on macOS](#first-launch-on-macos) below for exactly which dialogs you'll see and how to dismiss them once.

<a id="linux-cli"></a>
### Linux CLI

There's also a small companion `chronicle` CLI for Linux (and macOS) that reads the same `~/.claude/projects/` tree directly without the SQLite indexer. Useful on remote Linux dev boxes where the GUI app can't run.

```bash
# Pick the right architecture (x86_64 or aarch64). Replace 0.1.4 with the
# version you want from the releases page.
VERSION=0.1.4
ARCH=$(uname -m); case "$ARCH" in aarch64|arm64) ARCH=aarch64 ;; *) ARCH=x86_64 ;; esac

curl -fsSL "https://github.com/josephyaduvanshi/claude-history-manager/releases/download/v${VERSION}/chronicle-${VERSION}-linux-${ARCH}.tar.gz" \
  | tar xz -C /tmp
sudo install -m 0755 /tmp/chronicle /usr/local/bin/chronicle
chronicle --version
```

Verify the SHA256 if you want — the release page lists `chronicle-<version>-linux-<arch>.tar.gz.sha256` next to each tarball.

The CLI exposes four commands:

```bash
chronicle list                       # workspaces with session counts + last activity
chronicle sessions [-w <workspace>]  # sessions in a workspace, newest first
chronicle search "EXC_BAD_ACCESS"    # substring search across every transcript
chronicle show <session-id>          # print a transcript (use --format raw for JSONL)
```

It's Foundation-only Swift, statically linked against the Swift stdlib, single-file. No daemon, no SQLite, no FTS index — it reads the JSONL files on demand and stays out of your way.

<a id="first-launch-on-macos"></a>
### First launch on macOS — what Gatekeeper will show you

Chronicle is **ad-hoc signed, not notarized**. That's a one-time UX cost, not a quality cost. Here's exactly what each install method asks of you the first time, and never again.

| Install method | What macOS shows on first launch | What you do | What it costs you |
|---|---|---|---|
| `brew install --cask chronicle` | Nothing — Homebrew runs the `.pkg`, the `.pkg`'s postinstall strips the quarantine attribute on `/Applications/Chronicle.app`, and the app opens clean. | Just `brew install --cask chronicle`. | One Gatekeeper warning on the *installer* the very first time you run a `.pkg` from this project; future tap updates don't re-prompt. |
| Download `.pkg` | "macOS cannot verify the developer of this package." | Right-click the `.pkg` → **Open** → **Open** in the second dialog. | One extra click. |
| Download `.dmg` | "Apple could not verify Chronicle is free of malware." | Run `xattr -cr /Applications/Chronicle.app` in Terminal once, or right-click `Chronicle.app` → **Open** → **Open**. | One extra click *or* one shell command. |
| Download `.zip` | Same as `.dmg`. | Same as `.dmg`. | Same. |

**Why does this happen?** Apple's Gatekeeper trusts binaries signed with a paid Developer ID and notarized by Apple's servers. Chronicle is signed with an ad-hoc key (no developer account on this project yet), so macOS asks you to confirm once that you trust the source. After that confirmation, the binary launches normally forever.

**Privacy note.** The Gatekeeper warning is *not* a malware detection — Apple just hasn't notarized this build. The app's source is in this repository, the GitHub Actions workflow at `.github/workflows/release.yml` builds the binary you download, and every release lists a `.shasums` file so you can verify the bytes if you care.

If you want zero-friction installs and are willing to spend $99/year, see [issue #1](https://github.com/josephyaduvanshi/claude-history-manager/issues) for the notarization roadmap.

### Build from source

Chronicle is a pure Swift Package. No Xcode project, no signing setup, no Brewfile. If you have a recent Xcode toolchain installed, you have everything you need.

```bash
git clone https://github.com/josephyaduvanshi/claude-history-manager.git
cd claude-history-manager
swift build -c release
.build/release/Chronicle
```

Running the raw binary works for hacking on it. For a real `.app` bundle (the kind macOS treats like a normal application, with a Dock icon and proper `Info.plist`), use the GitHub Actions workflow at `.github/workflows/release.yml` as a template, or copy the binary into a hand-rolled bundle alongside `Resources/Info.plist.in`.

---

## How it works

Chronicle is a SwiftUI app on top of two boring layers. Parsers read each provider's transcript format. Claude and Codex use JSON Lines (one event per line); Gemini uses a single JSON file per session. The parser pulls out title, message count, token usage, model, tools used, and timestamps, then writes that into SQLite via [GRDB](https://github.com/groue/GRDB.swift). A file-system watcher reindexes only the files whose size or `mtime` actually changed, so a warm cache for 35 workspaces and 440 sessions reopens in around 75 milliseconds.

Full-text search hits an FTS5 virtual table that's built lazily the first time you type `/full:`. Everything else (the menubar, the stats dashboard, the heatmaps, the smart folders) runs against the same in-process SQLite handle. There's no daemon, no background process, no helper binary. When the app isn't running, nothing is running.

Bootstrap was originally 35 fsyncs (one per workspace). It's now 1 fsync inside a single `SAVEPOINT`, with workspace metadata cached and `file_mtime` stored as a `REAL` epoch with a 50ms tolerance window so we don't reparse files just because APFS rounded a timestamp differently.

---

## Features

### Search and slash filters

Title search runs against indexed metadata for instant results. Type `/full: error handling` to drop into FTS5 transcript search. Combine filters with `/today`, `/tag:client-work`, `/in:flutter`, `/model:opus`, and free text in any order. The query bar parses left-to-right, so `/in:rust /tag:bug panic` means "Rust workspaces, tagged bug, with the word panic anywhere in the title".

### Workspaces, color-coded

Every provider stores sessions under a different layout. Claude Code uses `~/.claude/projects/` with the project path encoded as a folder name like `-Users-you-Code-flutter-myapp`. Codex writes rollouts to `~/.codex/sessions/<year>/<month>/<day>/rollout-*.jsonl` and groups by each session's `cwd`. Gemini writes chats to `~/.gemini/tmp/<project-dir>/chats/session-*.json`. Chronicle decodes all three back into real paths, then buckets each workspace into one of nine categories: AI/CLAUDE, FLUTTER, SECURITY, RUST, GO, PYTHON, WEB, WORK, OTHER. Each category gets its own hue in the sidebar and click-to-collapse headers, so the workspace list stays scannable even when you have 35 of them.

### Smart folders

Built-in: Today, This week, Used `git push`, Errored sessions, Long sessions. You can also save any combined query as a custom folder. The combined filter takes workspace, tag, token range, date range, flags (pinned, archived, has-notes), and free text, all in one folder definition.

### Tags, pins, archive, soft-delete

Right-click any session to pin it, tag it with a color hue, archive it, or move it to Trash with a 30-day undo window. Renaming sticks. Notes stick. Nothing is destructive without a confirmation, and nothing touches the underlying JSONL files.

### Transcript view

Markdown-rendered conversation with [Splash](https://github.com/JohnSundell/Splash)-highlighted code blocks, collapsible tool calls, and a TOC sidebar listing every message and tool call in the session. The right-hand metadata pane shows started-at, duration, model (the actual model — `gpt-5.4`, `gemini-3-flash-preview`, `claude-sonnet-4-5`, etc., not the API host), total tokens, files touched, and tools used. Files Touched is extracted from each provider's actual tool calls (Claude's `Write`/`Edit`, Codex's `apply_patch` and read-shaped `exec_command`, Gemini's `write_file`).

<p align="center">
  <img src="docs/branding/screenshots/04-transcript.png" alt="Transcript view with TOC and metadata sidebar" width="900">
</p>

### Stats dashboard

Per-project tokens and an estimated cost using the standard pricing tiers. An hour-by-weekday activity heatmap so you can see when you actually work. A 90-day calendar heatmap with hover popovers showing the top three workspaces and total tokens for each day. Both heatmaps are fed by the same in-process SQLite so they update without an extra query layer.

<p align="center">
  <img src="docs/branding/screenshots/02-stats.png" alt="Stats dashboard with totals, cost-by-model, and per-project usage" width="900">
</p>

### Resume in your terminal

`Resume in <Terminal>` launches the selected session in Ghostty, iTerm, Terminal.app, Alacritty, WezTerm, or kitty. The launcher routes to the right CLI for the session's provider: `claude --resume <uuid>` for Claude, `codex resume <uuid>` for Codex (subcommand, not a flag), `gemini --resume <uuid>` for Gemini. Pick a default terminal in Settings, or override per-session from the action bar dropdown. The launcher uses the right invocation for each terminal (e.g. `ghostty --working-directory=...`, AppleScript for iTerm) and degrades gracefully if a terminal isn't installed.

Heads up: when you click "Resume in Ghostty", Ghostty pops a one-time-per-click "Allow Ghostty to execute ..." confirmation. That's a Ghostty security gate ([discussion #10203](https://github.com/ghostty-org/ghostty/discussions/10203)) that can't be turned off in config. The other terminals don't have this prompt.

### Open in your editor

`Open in <Editor>` launches alongside the terminal: VS Code, Cursor, Zed, or Xcode. Detection resolves the installed `.app` bundle first, then falls back to a CLI shim on `PATH`. Same per-session override pattern as the terminal launcher.

### Menubar dropdown

Press `⌘⇧O` from anywhere on the system. A 480px popover drops down from the menubar showing live, recent, and pinned sessions, with `⌘1` through `⌘9` to launch any visible row. The same global hotkey toggles it closed. `⌘⇧⏎` resumes the most-recently-modified session in your default terminal without opening any UI at all.

### Live session detection

A green pulse marks sessions any of the three CLIs is currently writing to. Polled every two seconds against the watched directories for the active provider. Useful when you have three terminals running at once and need to figure out which one is the active conversation.

### iCloud Drive metadata sync

Pins, tags, archive flags, smart folders, custom titles, and notes sync via a single JSON file at `~/Library/Mobile Documents/com~apple~CloudDocs/Chronicle/chronicle-sync.json`. Every record carries the provider it belongs to, so a Codex pin on Mac A doesn't show up under Claude on Mac B. Transcripts stay on the device they were generated on. The sync model is last-write-wins per record with a small per-tag merge so two of your own machines stay consistent. It is not designed for collaborative editing, which Chronicle doesn't support.

### Quick Look

Press `⌘Y` on any selected session for a 300x480 popover preview of the first ~40 lines of the transcript, no full window open. Same gesture as Finder's Quick Look. Esc dismisses.

### In-app auto-update

`Check for updates…` in the app menu fetches the appcast from the latest GitHub Release and, if a newer version is available, downloads, verifies, and swaps the running bundle in place via [Sparkle](https://sparkle-project.org). Each release zip is signed with an EdDSA private key held only in CI; the matching public key is embedded in the app, so a tampered download fails verification and is rejected before it touches your `/Applications` folder. No background polling — the only outbound network call the app makes is the one you trigger by clicking that menu item.

---

## Privacy

Chronicle runs entirely on your Mac. The app reads `~/.claude/projects/`, `~/.codex/sessions/`, and `~/.gemini/tmp/` for session data, and writes a single SQLite database to `~/Library/Application Support/Chronicle/chronicle.sqlite`. That's it. Transcripts are not uploaded, summarized, embedded, or sent to any external service.

When you turn iCloud sync on, Chronicle writes one file inside your iCloud Drive: `~/Library/Mobile Documents/com~apple~CloudDocs/Chronicle/chronicle-sync.json`. That file contains tags, pin flags, archive flags, custom titles, notes, and smart-folder definitions. It does not contain transcripts, message bodies, file paths beyond the workspace name, or any session content. If you want to see exactly what's in there, open the file. It's plain JSON.

There is no telemetry, no crash reporter, no analytics, no "anonymous usage data". The only outbound network call the app makes is the GitHub Releases check, and only when you click `Check for updates...`.

---

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘K` | Focus the global search field |
| `⌘1` | Switch to the Sessions tab |
| `⌘2` | Switch to the Stats tab |
| `⌘Y` | Quick Look the selected session |
| `⌘,` | Open Settings |
| `⌘⇧O` | Toggle the menubar dropdown from anywhere |
| `⌘⇧⏎` | Resume the most-recently-modified session in your default terminal |
| `↑` / `↓` | Move the selection in any list |
| `⏎` | Resume the selected session in the default terminal |
| `⌘⏎` | Open the terminal picker for the selected session |
| `⌘1`-`⌘9` (in menubar) | Launch the Nth visible row |
| `⎋` | Dismiss the menubar dropdown or any sheet |

---

## Configuration

Settings (`⌘,`) is grouped into four panes:

**Appearance.** Seven named themes, all with full custom palettes — not just light/dark inversions of the same base.

| Theme | Mode | Vibe |
|---|---|---|
| Dark Chronicle | dark | Default. Coral on near-black, the look you see in the screenshots above. |
| Github | light | GitHub Light feel. Blue accent, clean white surfaces. |
| Gothic | dark | Deep purple on near-black. Blood-red highlights. |
| Newsprint | light | Sepia and cream. Warm brown accent. Reads like a paperback. |
| Night | dark | True midnight blue. Cobalt accent. Cold and surgical. |
| Pixyll | light | Tufte-flavored white. Red accent. Sharp narrow rules. |
| Whitey | light | Near-monochrome. Coral accent stays. The minimal end of the spectrum. |

Plus eight coral accent presets and a custom color picker (these only apply to Dark Chronicle and Whitey, the two themes designed around coral). Three density modes: compact, comfortable, spacious. Density affects row height, padding, and the metadata pane's font size.

**Sync.** Toggle iCloud Drive sync on or off. Shows last-pull and last-push timestamps. `Sync now` forces a pull-then-push round trip. Surfaces the last error inline if a write failed (usually because iCloud Drive is paused or the user isn't signed in).

**Terminal.** Pick the default terminal for resume actions. Detects which of Ghostty, iTerm, Terminal.app, Alacritty, WezTerm, and kitty are installed and only shows the available ones.

**Editor.** Pick the default editor for `Open in <Editor>` actions: VS Code, Cursor, Zed, or Xcode. Same install-detection logic as Terminal.

Preferences live in `UserDefaults` under the `chronicle.*` keys. The SQLite database lives at `~/Library/Application Support/Chronicle/chronicle.sqlite`. Removing the support folder gives you a clean re-index on next launch.

---

## FAQ

### Why macOS 15 only?

Chronicle uses SwiftUI features and font APIs (variable-font width and optical sizing on `Font.custom`) that ship in macOS 15. Backporting to 14 means rewriting the type system and dropping a few visual touches. macOS 15 has been out long enough to be widely adopted, so the trade isn't worth it. If you're not on macOS 15, this won't even launch.

### How do I uninstall?

Drag `Chronicle.app` from `/Applications/` to the Trash, then remove the database and preferences:

```bash
rm -rf ~/Library/Application\ Support/Chronicle
defaults delete com.chronicle.app
```

If you turned on iCloud sync and want to wipe the cloud copy too, delete `~/Library/Mobile Documents/com~apple~CloudDocs/Chronicle/`.

### Where is my data stored?

All on your Mac, in a few different places:

- `~/.claude/projects/`, `~/.codex/sessions/`, and `~/.gemini/tmp/` are the source-of-truth transcripts each CLI writes. Chronicle reads these but never writes to them.
- `~/Library/Application Support/Chronicle/chronicle.sqlite` is Chronicle's own index, plus your pins, tags, notes, custom titles, and smart-folder definitions. Every record carries which provider it belongs to so the three datasets stay separate.
- `~/Library/Mobile Documents/com~apple~CloudDocs/Chronicle/chronicle-sync.json` is only present if you turned on iCloud sync. Metadata only — no transcripts.

### Is the app sandboxed?

No. Chronicle reads from `~/.claude/projects/`, `~/.codex/sessions/`, and `~/.gemini/tmp/`, writes to its own Application Support folder, and shells out to launch terminals. None of that works under the App Sandbox. If a future App Store release happens, sandboxing is on the table; for now, the binary is plain and unsandboxed.

### Can I sync to iCloud?

Yes. Toggle it on in Settings > Sync. Only metadata syncs (tags, pins, notes, custom titles, smart-folder definitions). Transcripts stay on the device they were generated on, because they live under each CLI's own folder and those CLIs write per-machine. Every synced record carries the provider it belongs to, so a Codex pin doesn't show up under Claude on the other Mac.

### Why is the app ad-hoc signed instead of notarized?

Notarization requires a paid Apple Developer ID ($99/year). This project doesn't have one yet. Until that changes, Chronicle ships ad-hoc signed and you'll need to run `xattr -cr /Applications/Chronicle.app` once on first install. The first-launch in-app card detects the quarantine attribute and shows the command with a copy button so you don't have to remember it.

### Is this a plugin for Claude Code, Codex, or Gemini?

No. Chronicle is a standalone macOS app. It reads the same files those CLIs write, but it doesn't hook into them, modify their behaviour, or require any of them to be running.

### Will it slow down my Mac?

The app idles at near-zero CPU when nothing is changing. The file-system watcher uses FSEvents, not polling, so an inactive workspace costs you nothing. The one place that does real work is the initial bootstrap on first launch, which takes 60 to 90 seconds for a few thousand sessions and only happens once.

---

## Contributing

Issues and pull requests are welcome at [github.com/josephyaduvanshi/claude-history-manager](https://github.com/josephyaduvanshi/claude-history-manager). If you're filing a bug, attach the output of `swift --version` and your macOS version. If you're proposing a feature, open an issue first so we can sanity-check the scope before you spend implementation time on it.

Run the tests before sending a PR:

```bash
swift test
```

The test suite uses fixture transcript files under `ChronicleTests/Fixtures/` (one folder per provider) so you don't need a populated `~/.claude/projects/`, `~/.codex/sessions/`, or `~/.gemini/tmp/` to run it.

---

## License

MIT. See [LICENSE](LICENSE).

The repository also bundles third-party fonts, libraries, and brand glyphs under their own licenses (MIT, SIL OFL 1.1, CC-BY-SA, CC0). Full attributions are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), the LICENSE file, and the [Credits](#credits) section below.

---

## Credits

Chronicle is built on a small set of excellent libraries and fonts:

- [GRDB.swift](https://github.com/groue/GRDB.swift) for SQLite + FTS5
- [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) for transcript rendering
- [NetworkImage](https://github.com/gonzalezreal/NetworkImage) (transitive) for the markdown image loader
- [Splash](https://github.com/JohnSundell/Splash) for code highlighting
- [Bricolage Grotesque](https://github.com/ateliertriay/bricolage) for display type
- [Geist](https://github.com/vercel/geist-font) and Geist Mono for body and monospace

All MIT or SIL OFL 1.1.

---

## Star History

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=josephyaduvanshi/claude-history-manager&type=date&theme=dark&legend=top-left" />
  <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=josephyaduvanshi/claude-history-manager&type=date&legend=top-left" />
  <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=josephyaduvanshi/claude-history-manager&type=date&legend=top-left" />
</picture>

---

<p align="center">
  Built by <a href="https://github.com/josephyaduvanshi">Joseph Yaduvanshi</a><br/>
  <sub>If this saved you an evening, a ⭐ on the repo is the nicest thank-you.</sub>
</p>
