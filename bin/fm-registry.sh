#!/usr/bin/env bash
# Resolve a project's delivery config from the first-mate registry (registry.md).
# The registry lives next to the skill; override with FIRST_MATE_REGISTRY.
#
# Usage:
#   fm-registry.sh resolve <name>   # prints: mode=<m> yolo=<y> projectId=<id|->
#   fm-registry.sh list             # prints the registry table
#   fm-registry.sh device           # prints the default deviceId
#
# An unknown/missing project resolves to "direct-PR off -" and warns to stderr,
# so a typo never silently grants extra autonomy. Only the rows between the
# <!-- registry:begin --> / <!-- registry:end --> markers are parsed.
set -eu

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="${FIRST_MATE_REGISTRY:-$SKILL_ROOT/registry.md}"
DEFAULT_DEVICE="${FIRST_MATE_DEVICE:-}"

cmd=${1:-}
case "$cmd" in
  device)
    [ -n "$DEFAULT_DEVICE" ] || {
      echo "error: no default device configured; set FIRST_MATE_DEVICE" >&2
      exit 1
    }
    echo "$DEFAULT_DEVICE"
    ;;
  list)
    [ -f "$REG" ] || { echo "error: no registry at $REG" >&2; exit 1; }
    awk '/<!-- registry:begin -->/{f=1;next} /<!-- registry:end -->/{f=0} f && NF' "$REG"
    ;;
  resolve)
    NAME=${2:?usage: fm-registry.sh resolve <name>}
    if [ ! -f "$REG" ]; then
      echo "warn: no registry at $REG; defaulting $NAME to direct-PR off" >&2
      echo "mode=direct-PR yolo=off projectId=- fork=-"
      exit 0
    fi
    line=$(awk -v n="$NAME" '
      /<!-- registry:begin -->/{f=1;next} /<!-- registry:end -->/{f=0}
      f {
        # split on | and trim each field
        nf=split($0,a,"|"); if (nf<1) next
        gsub(/^[ \t]+|[ \t]+$/,"",a[1])
        if (a[1]==n) { print; exit }
      }' "$REG")
    if [ -z "$line" ]; then
      echo "warn: project \"$NAME\" not in registry; defaulting to direct-PR off" >&2
      echo "mode=direct-PR yolo=off projectId=- fork=-"
      exit 0
    fi
    mode=$(echo "$line"  | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
    yolo=$(echo "$line"  | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}')
    pid=$(echo "$line"   | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}')
    fork=$(echo "$line"  | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$5); print $5}')
    case "$mode" in direct-PR|local-only) ;; *) echo "warn: unknown mode \"$mode\" for $NAME; using direct-PR" >&2; mode=direct-PR ;; esac
    case "$yolo" in on|off) ;; *) yolo=off ;; esac
    [ -n "$pid" ] || pid='-'
    [ -n "$fork" ] || fork='-'
    echo "mode=$mode yolo=$yolo projectId=$pid fork=$fork"
    ;;
  cloud-project)
    # Resolve a project's Superset CLI/cloud project id, live from `superset projects
    # list` (drift-proof). Falls back to the registry's stored id if the CLI is
    # unavailable/unauthed. Prints the id, or errors if it can't be resolved.
    NAME=${2:?usage: fm-registry.sh cloud-project <name>}
    id=""
    if command -v superset >/dev/null 2>&1; then
      id=$(superset projects list --json 2>/dev/null | python3 -c "import sys,json
try:
    d=json.load(sys.stdin); ps=d if isinstance(d,list) else d.get('projects',d.get('data',[]))
    for p in ps:
        if p.get('name')=='$NAME' or p.get('slug')=='$NAME':
            print(p.get('id','')); break
except Exception: pass" 2>/dev/null)
    fi
    if [ -z "$id" ]; then
      # fall back to the stored projectId column
      eval "$("$0" resolve "$NAME")"   # sets projectId
      id=$projectId
    fi
    [ -n "$id" ] && [ "$id" != "-" ] || { echo "error: cannot resolve cloud project id for \"$NAME\" (run: superset auth login, or add the id to registry.md)" >&2; exit 1; }
    echo "$id"
    ;;
  *)
    echo "usage: fm-registry.sh {resolve <name>|cloud-project <name>|list|device}" >&2
    exit 2
    ;;
esac
