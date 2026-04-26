#!/usr/bin/env bash
# Emit a Sparkle 2.x appcast.xml RSS feed listing the most recent
# published, non-draft, non-prerelease releases of Chronicle.
#
# Inputs (from env):
#   - REF_NAME — the tag currently being released, e.g. "v0.2.1".
#   - GH_TOKEN — passed as github.token by the workflow.
#   - GITHUB_REPOSITORY — "owner/repo", default josephyaduvanshi/claude-history-manager.
#
# Inputs (from disk):
#   - sparkle-attrs.txt — single-line `sparkle:edSignature="..."
#     length="..."` emitted by `sign_update Chronicle-<v>.zip` in the
#     prior CI step.
#
# Output: full appcast.xml on stdout.
#
# Older releases are listed without a sparkle:edSignature attribute so
# Sparkle reports them as untrusted and skips them. Only the current
# release's signed entry actually drives upgrades. The historical
# entries exist purely so Sparkle's "all versions" pane has continuity;
# backfilling old signatures is a documented follow-up.

set -euo pipefail

REPO="${GITHUB_REPOSITORY:-josephyaduvanshi/claude-history-manager}"
CURRENT_TAG="${REF_NAME:?REF_NAME (e.g. v0.2.1) must be set}"
CURRENT_VER="${CURRENT_TAG#v}"

if [ ! -f sparkle-attrs.txt ]; then
  echo "::error::sparkle-attrs.txt missing — sign_update step must run before this script" >&2
  exit 1
fi
CURRENT_ATTRS="$(cat sparkle-attrs.txt)"

cat <<XML_HEADER
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Chronicle</title>
    <link>https://github.com/${REPO}</link>
    <description>Updates for Chronicle, the macOS browser for CLI coding-assistant session histories.</description>
    <language>en</language>
XML_HEADER

# Pull the most recent 30 releases. Filter draft + prerelease in jq;
# emit one compact JSON line per release for the bash loop below.
gh api "repos/${REPO}/releases?per_page=30" \
  | jq -c '.[] | select(.draft == false) | select(.prerelease == false) | {tag: .tag_name, name: .name, body: .body, pub: .published_at, assets: .assets}' \
  | while IFS= read -r release; do
      tag=$(echo  "$release" | jq -r '.tag')
      name=$(echo "$release" | jq -r '.name // .tag')
      body=$(echo "$release" | jq -r '.body // ""')
      pub=$(echo  "$release" | jq -r '.pub')
      ver="${tag#v}"

      zip_url=$(echo "$release" \
        | jq -r --arg v "$ver" '.assets[] | select(.name == "Chronicle-\($v).zip") | .browser_download_url' \
        | head -n 1)
      if [ -z "$zip_url" ] || [ "$zip_url" = "null" ]; then
        # No .zip asset for this release — skip rather than emit a broken item.
        continue
      fi

      # RFC3339 → RFC822 for RSS. Try GNU date first (Linux runners),
      # fall back to BSD date -j -f (macOS runners).
      pub_date=$(date -u -d "$pub" "+%a, %d %b %Y %H:%M:%S +0000" 2>/dev/null \
                 || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$pub" "+%a, %d %b %Y %H:%M:%S +0000" 2>/dev/null \
                 || echo "")

      if [ "$tag" = "$CURRENT_TAG" ]; then
        attrs="$CURRENT_ATTRS"
      else
        attrs=""
      fi

      # Break any literal ]]> sequence inside the body so it doesn't
      # close the CDATA section prematurely.
      safe_body=$(printf '%s' "$body" | sed 's/]]>/]]]]><![CDATA[>/g')

      # Title needs basic XML entity escaping since it sits in element
      # content (not CDATA).
      safe_name=$(printf '%s' "$name" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

      # Compute the same packed-integer build number that the
      # Construct .app bundle step writes into each release's
      # CFBundleVersion: major*10000 + minor*100 + patch.
      # 0.2.1 → 201, 0.2.0 → 200, 0.1.6 → 106. Sparkle compares
      # CFBundleVersion (sparkle:version in the appcast) first, so
      # this monotonicity is what drives upgrade detection.
      IFS='.' read -r M m p <<< "$ver"
      p="${p%%-*}"
      build_number=$(( ${M:-0} * 10000 + ${m:-0} * 100 + ${p:-0} ))

      cat <<ITEM
    <item>
      <title>${safe_name}</title>
      <pubDate>${pub_date}</pubDate>
      <sparkle:version>${build_number}</sparkle:version>
      <sparkle:shortVersionString>${ver}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[${safe_body}]]></description>
      <enclosure url="${zip_url}" type="application/octet-stream" ${attrs}/>
    </item>
ITEM
    done

cat <<XML_FOOTER
  </channel>
</rss>
XML_FOOTER
