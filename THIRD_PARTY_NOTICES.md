# Third-party notices

Chronicle is licensed under [MIT](LICENSE). The following third-party assets and code are bundled or distributed with Chronicle and ship under their own terms.

## Bundled brand glyphs

Chronicle ships monochrome PDF/SVG glyphs identifying the three CLI providers it integrates with. The glyphs are used **for nominative identification only** — to help users tell at a glance which provider's sessions are being shown. None of the providers below endorse or sponsor Chronicle.

### `Chronicle/Resources/ProviderIcons/claude.{svg,pdf}`

- **Glyph**: Anthropic / Claude burst
- **Source**: [`https://claude.ai/favicon.svg`](https://claude.ai/favicon.svg)
- **Trademark**: Claude® and the Claude burst mark are trademarks of Anthropic PBC. Used here under nominative fair use to identify Claude Code sessions, not to suggest endorsement or affiliation.
- **Modifications**: Path data unchanged. The original `fill="#D97757"` was replaced with `fill="currentColor"` so the glyph picks up the active theme tint via `NSImage.isTemplate`.

### `Chronicle/Resources/ProviderIcons/codex.{svg,pdf}`

- **Glyph**: OpenAI 6-petal swirl
- **Source**: Path geometry derived from [Wikimedia Commons — `ChatGPT_logo.svg`](https://commons.wikimedia.org/wiki/File:ChatGPT_logo.svg).
- **Upstream license**: Wikimedia tags this asset as **CC-BY-SA 4.0**. The bundled `codex.svg` and `codex.pdf` are derivative works and inherit those terms — see [https://creativecommons.org/licenses/by-sa/4.0/](https://creativecommons.org/licenses/by-sa/4.0/). Attribution is provided here.
- **Trademark**: OpenAI® and the OpenAI logomark are trademarks of OpenAI OpCo, LLC. Used here under nominative fair use to identify Codex CLI sessions, not to suggest endorsement or affiliation. Trademark rights are not affected by the CC license on the SVG file itself.
- **Modifications**: The colored badge background was dropped; `<use href="#a">` rotation references were flattened to explicit `<path>` elements with `transform="rotate(...)"` for stable PDF tinting; root `fill` set to `currentColor`.

### `Chronicle/Resources/ProviderIcons/gemini.{svg,pdf}`

- **Glyph**: Google Gemini concave 4-pointed star
- **Source**: [Simple Icons — `googlegemini`](https://simpleicons.org/?q=googlegemini) (`https://cdn.simpleicons.org/googlegemini`)
- **Upstream license**: Simple Icons SVG sources are released under [CC0 1.0 (public domain dedication)](https://creativecommons.org/publicdomain/zero/1.0/).
- **Trademark**: Gemini™ and the Gemini logomark are trademarks of Google LLC. Used here under nominative fair use to identify Gemini CLI sessions, not to suggest endorsement or affiliation. CC0 on the SVG file does not waive any underlying trademark.
- **Modifications**: Root `fill` set to `currentColor`.

If you are a representative of Anthropic, OpenAI, or Google and prefer that Chronicle stop bundling your mark, please open an issue at <https://github.com/josephyaduvanshi/claude-history-manager/issues> and we'll swap the asset for a brand-derived monochrome alternative.

## Other bundled code

See `Package.swift` for the full Swift Package Manager dependency list (GRDB, Splash, etc.). Each dependency ships under its own license; refer to its repository.

### Sparkle

- **Source**: <https://github.com/sparkle-project/Sparkle>
- **License**: [MIT](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE).
- **Role**: Drives Chronicle's in-app auto-update flow (download, EdDSA signature verification, atomic bundle swap, relaunch). The public key matching Chronicle's release-signing private key is committed in `Chronicle/Resources/Info.plist.in` under the `SUPublicEDKey` plist key.
