#!/usr/bin/env bash
# Host visual artifacts (screenshots, before/after PNGs) on UploadThing and print
# ready-to-paste GitHub markdown image embeds to stdout -- one `![name](url)` per
# file. This is how a crewmate surfaces visual proof in a PR: an autonomous,
# headless session can't drag-drop into GitHub's web uploader (that needs a logged-in
# browser), but it CAN host the image externally and embed it by URL. Pairs with
# `gh pr comment <n> --body-file ...` or a PR body.
#
# Usage:
#   fm-upload-shots.sh <image> [<image> ...]
#   fm-upload-shots.sh --raw <image> ...     # print `name<TAB>url`, no markdown
#
# Output (stdout): one markdown image line per input, in input order. Diagnostics
# and SDK deprecation chatter go to stderr; stdout stays clean for piping/embedding.
#
# Auth: reads the UploadThing token from the 1Password reference provided in
# $FM_UPLOADTHING_OP_REF. The token format is the v6/v7 UPLOADTHING_TOKEN
# (base64 JSON with apiKey/appId/regions).
set -eu

RAW=0
case "${1:-}" in
  --raw) RAW=1; shift ;;
  -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
[ $# -ge 1 ] || { echo "fm-upload-shots: need at least one image path" >&2; exit 2; }

for f in "$@"; do
  [ -f "$f" ] || { echo "fm-upload-shots: no such file: $f" >&2; exit 2; }
done

OP_REF="${FM_UPLOADTHING_OP_REF:-}"
[ -n "$OP_REF" ] || {
  echo "fm-upload-shots: set FM_UPLOADTHING_OP_REF to an op://... reference" >&2
  exit 1
}
UT_TOKEN="$(op read "$OP_REF" 2>/dev/null || true)"
[ -n "$UT_TOKEN" ] || {
  echo "fm-upload-shots: could not read UploadThing token from $OP_REF" >&2
  echo "  (is the op service-account token loaded, and is the referenced vault reachable?)" >&2
  exit 1
}

# Cache the SDK once so repeated calls across a fleet don't reinstall.
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/fm-uploadthing"
mkdir -p "$CACHE"
if [ ! -d "$CACHE/node_modules/uploadthing" ]; then
  echo "fm-upload-shots: installing uploadthing SDK (one-time) ..." >&2
  ( cd "$CACHE" && { [ -f package.json ] || npm init -y >/dev/null 2>&1; } \
      && npm i uploadthing >/dev/null 2>&1 ) \
    || { echo "fm-upload-shots: npm install uploadthing failed" >&2; exit 1; }
fi

cat > "$CACHE/upload.mjs" <<'JS'
import { UTApi } from "uploadthing/server";
import fs from "node:fs";
import path from "node:path";
const utapi = new UTApi(); // reads UPLOADTHING_TOKEN from env
const paths = process.argv.slice(2);
const files = paths.map((p) => {
  const buf = fs.readFileSync(p);
  const ext = path.extname(p).toLowerCase();
  const type = ext === ".jpg" || ext === ".jpeg" ? "image/jpeg"
    : ext === ".gif" ? "image/gif" : ext === ".webp" ? "image/webp" : "image/png";
  return new File([new Uint8Array(buf)], path.basename(p), { type });
});
const res = await utapi.uploadFiles(files);
const out = res.map((r, i) => ({
  name: path.basename(paths[i]),
  url: r.data?.ufsUrl ?? r.data?.url ?? null,
  error: r.error ? String(r.error.message ?? r.error) : null,
}));
process.stdout.write(JSON.stringify(out));
JS

RESULT="$(cd "$CACHE" && UPLOADTHING_TOKEN="$UT_TOKEN" node upload.mjs "$@" 2>/dev/null)" \
  || { echo "fm-upload-shots: upload failed" >&2; exit 1; }

# Format with node (stable JSON parse); fall back to nothing on parse error.
printf '%s' "$RESULT" | RAW="$RAW" node -e '
let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
  let arr; try { arr=JSON.parse(s); } catch { process.exit(1); }
  let bad=0;
  for (const r of arr) {
    if (r.error || !r.url) { console.error("fm-upload-shots: "+r.name+": "+(r.error||"no url")); bad=1; continue; }
    const label = r.name.replace(/\.[a-z]+$/i,"");
    if (process.env.RAW==="1") console.log(r.name+"\t"+r.url);
    else console.log("!["+label+"]("+r.url+")");
  }
  process.exit(bad);
});'
