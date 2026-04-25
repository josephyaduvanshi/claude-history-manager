---
name: Bug report
about: Something is broken or behaves unexpectedly
labels: bug
---

## What happened

A clear description of the bug.

## Steps to reproduce

1.
2.
3.

## What you expected

What you thought would happen instead.

## Environment

- Chronicle version: (e.g. `0.1.0`, see `Chronicle → About`)
- macOS version: (e.g. `15.2`, see `About This Mac`)
- Hardware: (Apple Silicon / Intel)
- Install method: `.pkg` / `.dmg` / `.zip` / built from source

## Logs

If the app didn't crash but is misbehaving, run this in Terminal and paste the last 20 lines:

```bash
log show --predicate 'subsystem == "app.chronicle.Chronicle"' --info --last 5m
```

If the app crashed, attach the crash report from `~/Library/Logs/DiagnosticReports/Chronicle-*.ips`.

## Anything else

Screenshots, related sessions, weird workspace paths, anything that helps narrow it down.
