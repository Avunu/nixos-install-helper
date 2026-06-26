#!/usr/bin/env bash
set -euo pipefail
# ════════════════════════════════════════════════════════════════════════════
#  deploy.sh — network install via nixos-anywhere. Workstation-side.
#  Stages secret assets into a tree and pushes them with --extra-files.
#  Usage:  nix run .#deploy -- root@<ip>
# ════════════════════════════════════════════════════════════════════════════

FLAKE="${IH_FLAKE_REF:-.}"
TARGET="${1:-}"
[ -z "$TARGET" ] && TARGET=$(gum input --header "Target SSH host" --placeholder "root@192.0.2.10")
[ -z "$TARGET" ] && { echo "No target host given."; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# Stage each declared asset under STAGE mirroring its absolute target path.
while read -r asset; do
    [ -z "$asset" ] && continue
    name=$(jq -r '.name' <<<"$asset")
    target=$(jq -r '.target' <<<"$asset")
    mode=$(jq -r '.mode // "0400"' <<<"$asset")
    env=$(jq -r '.source.env // empty' <<<"$asset")
    file=$(jq -r '.source.file // empty' <<<"$asset")
    dst="${STAGE}${target}"
    mkdir -p "$(dirname "$dst")"

    if [ -n "$env" ] && [ -n "${!env:-}" ]; then
        printf '%s' "${!env}" > "$dst"
    elif [ -n "$file" ] && [ -e "$file" ]; then
        cp "$file" "$dst"
    else
        gum confirm "Provide asset '${name}' (→ ${target})?" || { rmdir "$(dirname "$dst")" 2>/dev/null || true; continue; }
        method=$(gum choose --header "How to provide ${name}?" "Read from a file" "Paste contents")
        if [ "$method" = "Read from a file" ]; then
            cp "$(gum file --header "Select ${name}")" "$dst"
        else
            gum write --header "Paste ${name} (Ctrl+D when done)" > "$dst"
        fi
    fi
    [ -e "$dst" ] && chmod "$mode" "$dst"
done < <(jq -c '.[]?' "${IH_ASSETS:-/dev/null}" 2>/dev/null || true)

extra=()
if [ -n "$(find "$STAGE" -type f 2>/dev/null)" ]; then
    extra=(--extra-files "$STAGE")
fi

gum confirm "Install ${FLAKE}#install onto ${TARGET}? This WIPES its disks." || { echo "Aborted."; exit 1; }

exec nixos-anywhere "${extra[@]}" --flake "${FLAKE}#install" --target-host "$TARGET"
