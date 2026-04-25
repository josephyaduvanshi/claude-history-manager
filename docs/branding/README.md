# Chronicle Icon Branding

This directory contains the production icon exports for Chronicle, the native macOS Claude Code session history browser.

## Palette

- Background base: `#0E0F12`
- Accent coral: `#FF7A4D`
- Corner gradient target: `#1A1C20`

Rationale: the icon keeps the app in the same visual family as `Theme.Color.bg` and the existing coral `CL` menubar mark in [ChronicleApp.swift](/Users/josephyaduvanshi/Code/swift/apps/claude-history-manager/Chronicle/ChronicleApp.swift:120). The exported background is a slightly cleaner near-black than the in-app surface token so the icon stays crisp in the macOS dock while still reading as Chronicle's dark UI. The coral frame and condensed `CL` directly mirror the app's menubar badge geometry and accent usage.

Font note: the generator prefers condensed bold system faces. On this machine it resolves to `Arial Narrow Bold` from `/System/Library/Fonts/Supplemental/Arial Narrow Bold.ttf`. If that font is unavailable later, the script falls back to `DIN Condensed Bold`, `Avenir Next Condensed`, `HelveticaNeue`, `SFNS`, then `Arial Bold`.

## Variants

- `icon-1024-v1.png`: clean minimal export with the `CL` mark and coral frame on the dark field.
- `icon-1024-v2.png`: recommended export. Adds a faint horizontal scan-line texture at about 4% opacity for a terminal/log feel without introducing noise.
- `icon-1024-v3.png`: highlight variant. Adds a subtle top-left edge light on the outer squircle.

Recommendation: use `v2` as the shipping icon. It keeps the same restrained silhouette as `v1` but adds just enough texture to feel native to a session-history tool rather than a generic badge.

## Regenerate

Run:

```bash
python docs/branding/generate_icon.py
```

The script regenerates all three `1024x1024` PNGs, rebuilds `docs/branding/icon.iconset`, and produces `docs/branding/icon.icns` from `icon-1024-v2.png`.

The generator attempts the `sips` + `iconutil` chain first. If the local `iconutil` binary rejects an otherwise valid iconset on the current machine, the script falls back to Pillow's native ICNS writer so regeneration still completes with a valid `icon.icns`.

## iconutil Sequence

Use this exact chain if you want to rebuild the `.icns` manually from the recommended variant:

```bash
mkdir -p docs/branding/icon.iconset

sips -z 16 16 docs/branding/icon-1024-v2.png --out docs/branding/icon.iconset/icon_16x16.png
sips -z 32 32 docs/branding/icon-1024-v2.png --out docs/branding/icon.iconset/icon_16x16@2x.png

sips -z 32 32 docs/branding/icon-1024-v2.png --out docs/branding/icon.iconset/icon_32x32.png
sips -z 64 64 docs/branding/icon-1024-v2.png --out docs/branding/icon.iconset/icon_32x32@2x.png

sips -z 128 128 docs/branding/icon-1024-v2.png --out docs/branding/icon.iconset/icon_128x128.png
sips -z 256 256 docs/branding/icon-1024-v2.png --out docs/branding/icon.iconset/icon_128x128@2x.png

sips -z 256 256 docs/branding/icon-1024-v2.png --out docs/branding/icon.iconset/icon_256x256.png
sips -z 512 512 docs/branding/icon-1024-v2.png --out docs/branding/icon.iconset/icon_256x256@2x.png

sips -z 512 512 docs/branding/icon-1024-v2.png --out docs/branding/icon.iconset/icon_512x512.png
sips -z 1024 1024 docs/branding/icon-1024-v2.png --out docs/branding/icon.iconset/icon_512x512@2x.png

iconutil -c icns docs/branding/icon.iconset -o docs/branding/icon.icns
```

The `@2x` mapping is:

- `16x16@2x = 32x32`
- `32x32@2x = 64x64`
- `64x64@2x = 128x128`
- `128x128@2x = 256x256`
- `256x256@2x = 512x512`
- `512x512@2x = 1024x1024`

Apple's `.iconset` format does not use standalone `icon_64x64.png` or `icon_1024x1024.png` filenames. Those pixel sizes are represented by `icon_32x32@2x.png` and `icon_512x512@2x.png`.

## Install

Copy the icon into the app bundle resources:

```bash
cp docs/branding/icon.icns Chronicle.app/Contents/Resources/AppIcon.icns
```

Then ensure `Info.plist` uses:

```xml
<key>CFBundleIconFile</key>
<string>AppIcon</string>
```

No Swift sources or project files are modified by the generator.
