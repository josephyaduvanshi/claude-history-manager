# Contributing to Chronicle

Thanks for considering a contribution. The bar for merging is small enough that one person can hold it in their head, so this doc is short.

## Before you start

If your change is more than ~50 lines or touches the storage layer, open an issue first. Saves you from writing something that gets rejected on scope.

## Local setup

Chronicle is a Swift Package. No Xcode project to clone, no extra tools.

```bash
git clone https://github.com/josephyaduvanshi/claude-history-manager.git
cd claude-history-manager
swift build
swift test
```

You need macOS 15 Tahoe or later and Xcode 16 (Swift 6).

To run the app from a debug build:

```bash
swift run Chronicle
```

You'll be prompted to grant Full Disk Access on first launch so Chronicle can read `~/.claude/projects/`.

## What gets accepted

- Bug fixes, especially with a regression test
- Performance improvements with measurements (use the existing `AppLogger.app` instrumentation)
- New features that fit the privacy model: local-only, no telemetry, transcripts never leave the device
- Documentation improvements
- Tests for paths that don't have them

## What probably won't

- Cloud sync of transcripts. iCloud Drive metadata sync is the model; full transcript sync is out of scope
- Windows or Linux ports. Chronicle is macOS-native and uses native frameworks
- Backwards compatibility for macOS 14 or earlier. The codebase uses Swift 6 + macOS 15-only APIs
- Adding a paid backend service or external API call

## Code style

- Use `swift-format` defaults. The repo doesn't enforce it via CI yet, but matching what's there is appreciated
- Comments should be specific about WHY, not what. Don't leave AI-generated filler ("This function leverages...")
- Tests live in `ChronicleTests/`. Use `XCTest`, name methods `test_subject_does_thing()`
- New SwiftUI views go under `Chronicle/UI/`; if a view is general infrastructure (like the title bar), put it in `Chronicle/UI/Shell/`
- New repository methods go behind a focused protocol in `Chronicle/Repository/SessionsRepositoryProtocols.swift`. Don't dump everything on the composite

## Commit style

Conventional commits. Examples from the existing log:

```
feat(ui): hover and animation polish + ⌘Y Quick Look + safeMarkdown bound
fix(repo+launch): extract real cwd from jsonl, validate before launch
perf(repo): parallel workspace indexing via TaskGroup
```

Sign your commits with your real name and email. No bot or AI co-author lines.

## Filing PRs

The PR template asks the questions you'd want a reviewer to ask. Fill it in.

If your PR sits without a review for more than a week, ping the issue or @ me on the PR.
