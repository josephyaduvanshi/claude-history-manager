# Security

Chronicle reads your `~/.claude/projects/` folder, which can contain sensitive transcripts (API keys, passwords, file paths, internal architecture). If you find a security issue, please don't open a public GitHub issue.

## Reporting a vulnerability

Email: josefyaduvanshi@gmail.com with `[chronicle-security]` in the subject line.

Include:
- A description of the issue
- Steps to reproduce, ideally with a minimal repro
- The Chronicle version you're on (`Chronicle → About`)
- Whether the issue requires local filesystem access, network access, or specific user actions

I'll acknowledge within 72 hours and aim to ship a fix within 14 days for anything that affects user data or local privacy boundaries.

## Scope

In scope:
- Code that runs in `Chronicle.app` itself
- The release artifacts (`.zip`, `.dmg`, `.pkg`) and the workflows that build them
- The SQLite database at `~/Library/Application Support/Chronicle/chronicle.sqlite`
- The iCloud Drive sync file at `~/Library/Mobile Documents/com~apple~CloudDocs/Chronicle/chronicle-sync.json`

Out of scope:
- Vulnerabilities in Claude Code itself or the JSONL format it writes
- Privilege escalation that requires the user to already be root
- Issues that only manifest with sandboxed third-party software running with elevated privileges

## Privacy posture

Chronicle is a local-only app. No telemetry, no analytics, no remote logging. Transcripts never leave the Mac they were written on. The only network call is the optional update check against GitHub Releases, and that can be disabled in Settings. The iCloud sync (off by default) writes to your own iCloud Drive, not a Chronicle-controlled server.
