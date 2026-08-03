#!/usr/bin/env bash
set -euo pipefail
# ════════════════════════════════════════════════════════════════════════════
#  wizard.sh — the single entrypoint (`nix run .#` / `nix run github:Owner/repo`).
#  Walks the technician through: (optionally) collecting settings, then choosing a
#  deployment path — network install, unattended ISO, or guided ISO.
# ════════════════════════════════════════════════════════════════════════════

FLAKE="${IH_FLAKE_REF:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

gum style --border double --padding "1 2" --border-foreground 212 \
    "nixos-install-helper" "Guided deployment wizard"

# ── 1. Settings (only when this project exposes install-time options) ────────
# Each module namespace has its own FLAT settings file (IH_ROOTS).
if [ "${IH_HAS_SETTINGS:-0}" = "1" ]; then
    missing=0
    while IFS=$'\t' read -r _root file; do
        [ -z "$file" ] && continue
        [ -f "$file" ] || missing=1
    done < <(jq -r '.[] | [.root, .file] | @tsv' "${IH_ROOTS:-/dev/null}" 2>/dev/null || true)
    if [ "$missing" = "1" ]; then
        gum style "Some module settings files are missing — let's create them."
        bash "${SCRIPT_DIR}/configure.sh"
    elif gum confirm "Reconfigure module settings?" --default=false; then
        bash "${SCRIPT_DIR}/configure.sh"
    fi
fi

# ── 2. Deployment path ───────────────────────────────────────────────────────
options=("Network install  (nixos-anywhere over SSH — no USB)"
         "Unattended ISO   (pre-seeded, installs with no interaction)")
[ "${IH_GUIDED:-1}" = "1" ] && options+=("Guided ISO       (generic, choose identity on the target box)")
choice=$(printf '%s\n' "${options[@]}" | gum choose --header "How do you want to deploy?")

case "$choice" in
  Network*)
    exec bash "${SCRIPT_DIR}/deploy.sh" "$@"
    ;;
  Unattended*)
    attr="installerIso"; allow_impure=1 ;;
  Guided*)
    attr="guidedIso"; allow_impure=0 ;;
  *)
    echo "Nothing selected."; exit 1 ;;
esac

# Secrets sourced from env vars require an impure build (builtins.getEnv).
impure=()
if [ "${allow_impure}" = "1" ] && jq -e 'any(.[]; .source.env != null)' "${IH_ASSETS:-/dev/null}" >/dev/null 2>&1; then
    impure=(--impure)
    echo ":: env-sourced secrets detected — building --impure"
fi

gum spin --title "Building ${attr}…" -- \
    nix build "${impure[@]}" "${FLAKE}#${attr}" --print-build-logs

iso=$(find -L result/iso -name '*.iso' 2>/dev/null | head -1)
if [ -n "$iso" ]; then
    gum style --foreground 42 "ISO: $iso"
    echo "  Flash:  sudo dd if=\"$iso\" of=/dev/sdX bs=4M status=progress conv=fsync"
    echo "  Or boot it directly in a VM to test the install."
else
    echo "Build finished but no ISO was found under ./result/iso" >&2
fi
