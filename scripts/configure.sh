#!/usr/bin/env bash
set -euo pipefail
# ════════════════════════════════════════════════════════════════════════════
#  configure.sh — render each module namespace's FLAT schema as a gum
#  questionnaire and write a FLAT per-module settings JSON. Runs on the
#  technician's workstation. (nixos-router's router-settings.json pattern.)
#
#  Env (set by the mkProject app wrapper):
#    IH_ROOTS        path to [{ root, file, schema }] — one flat file per module
#    IH_HINTS        path to { "<dotted.path>": "disk-device" | "net-iface" }
#    IH_HAS_SETTINGS "1" if any module exposes options, else "0"
# ════════════════════════════════════════════════════════════════════════════

if [ "${IH_HAS_SETTINGS:-0}" != "1" ]; then
    gum style --foreground 42 "This project exposes no install-time options — nothing to configure."
    echo "Run the installer directly:  nix run .#install"
    exit 0
fi

HINTS=$(cat "${IH_HINTS:-/dev/null}" 2>/dev/null || echo '{}')

# Resolve a possibly-array JSON Schema `type` to a single primitive (nullable
# types appear as ["string","null"]).
prim_type() {
    jq -r '
      (.type // (if has("enum") then "enum" else "string" end)) as $t
      | if ($t|type) == "array" then ($t | map(select(. != "null")) | .[0]) else $t end
    ' <<<"$1"
}

hint_for() { jq -r --arg n "$1" '.[$n] // empty' <<<"$HINTS"; }

choose_disk() {
    lsblk -dn -o NAME,SIZE,MODEL 2>/dev/null | awk '{printf "/dev/%s  (%s %s)\n",$1,$2,$3}' \
        | gum choose --header "$1" | awk '{print $1}'
}
choose_iface() {
    ip -br link show 2>/dev/null | awk '$1!="lo"{print $1}' | gum choose --header "$1"
}

# Collect one value for a (sub)schema. Prints a JSON value.
collect_value() {
    local schema="$1" name="$2"
    local t; t=$(prim_type "$schema")
    local def; def=$(jq -c '.default // empty' <<<"$schema")
    local hint; hint=$(hint_for "$name")
    local desc; desc=$(jq -r '.description // empty' <<<"$schema")
    local header="$name"; [ -n "$desc" ] && header="$name — $desc"

    case "$t" in
      object) collect_object "$schema" "${name}." ;;
      boolean)
        if gum confirm "$header" --default="$(jq -r 'if .default==true then "true" else "false" end' <<<"$schema")"; then echo true; else echo false; fi ;;
      enum)
        local v; v=$(jq -r '.enum[]' <<<"$schema" | gum choose --header "$header")
        jq -n --arg v "$v" '$v' ;;
      integer|number)
        local d; d=$(jq -r '.default // "" | tostring' <<<"$schema")
        local v; v=$(gum input --header "$header" --value "$d")
        if [ -z "$v" ]; then echo "${def:-null}"; else jq -n --argjson v "$v" '$v'; fi ;;
      array)
        # array of strings → one per line
        local lines; lines=$(gum write --header "$header (one per line)")
        if [ -z "$lines" ]; then echo '[]'; else jq -R -s 'split("\n") | map(select(length>0))' <<<"$lines"; fi ;;
      string|*)
        local v
        case "$hint" in
          disk-device) v=$(choose_disk "$header") ;;
          net-iface)   v=$(choose_iface "$header") ;;
          *) local d; d=$(jq -r '.default // ""' <<<"$schema"); v=$(gum input --header "$header" --value "$d") ;;
        esac
        if [ -z "$v" ]; then echo "${def:-\"\"}"; else jq -n --arg v "$v" '$v'; fi ;;
    esac
}

# Walk an object schema's properties, building a JSON object.
collect_object() {
    local schema="$1" prefix="$2"
    local out='{}'
    local keys; keys=$(jq -r '.properties // {} | keys[]' <<<"$schema" 2>/dev/null || true)
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        local sub; sub=$(jq -c --arg k "$key" '.properties[$k]' <<<"$schema")
        local val; val=$(collect_value "$sub" "${prefix}${key}")
        out=$(jq -c --arg k "$key" --argjson v "$val" '. + {($k): $v}' <<<"$out")
    done <<<"$keys"
    echo "$out"
}

gum style --border double --padding "1 2" --border-foreground 212 \
    "Install configuration" "Answer the prompts; a flat settings file is written per module."

# One FLAT settings file per module namespace (root).
while IFS=$'\t' read -r root file schema; do
    [ -z "$root" ] && continue
    SCHEMA=$(cat "$schema")
    gum style --foreground 212 "── ${root} → ${file} ──"
    RESULT=$(collect_object "$SCHEMA" "")

    # Validate before writing (best-effort; non-fatal if the validator is absent).
    if command -v check-jsonschema >/dev/null 2>&1; then
        if ! echo "$RESULT" | check-jsonschema --schemafile "$schema" /dev/stdin >/dev/null 2>&1; then
            gum style --foreground 196 "Warning: ${root} settings did not validate against the schema (continuing)."
        fi
    fi

    mkdir -p "$(dirname "$file")"
    echo "$RESULT" | jq . > "$file"
    gum style --foreground 42 "Wrote ${file}"
done < <(jq -r '.[] | [.root, .file, .schema] | @tsv' "$IH_ROOTS")

echo "Next:  nix run .#install   (or re-run  nix run  for the full wizard)"
