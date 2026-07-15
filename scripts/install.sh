#!/usr/bin/env bash
set -euo pipefail
# ════════════════════════════════════════════════════════════════════════════
#  install.sh — pick a deployment path and build/launch it. Workstation-side.
# ════════════════════════════════════════════════════════════════════════════

FLAKE="${IH_FLAKE_REF:-.}"

show_iso() {
    local iso
    iso=$(find -L result/iso -name '*.iso' 2>/dev/null | head -1)
    if [ -n "$iso" ]; then
        gum style --foreground 42 "ISO: $iso"
        echo "  Flash:  sudo dd if=\"$iso\" of=/dev/sdX bs=4M status=progress conv=fsync"
    else
        echo "Build finished but no ISO found under ./result/iso" >&2
    fi
}

choice=$(gum choose --header "Deployment path:" \
    "Unattended ISO  (pre-seeded, per-host, installs with no interaction)" \
    "Guided ISO      (generic, boots into the menu, choose identity on the box)" \
    "Network install (nixos-anywhere over SSH to a reachable target)")

case "$choice" in
  Unattended*)
    # Impure build triggers (builtins.getEnv): env-sourced secrets, and the
    # untracked settings.json (flakes ignore untracked files → inject by path).
    impure=()
    if [ -f "installer/settings.json" ]; then
        impure=(--impure)
        IH_SETTINGS_FILE="$(realpath installer/settings.json)"
        export IH_SETTINGS_FILE
        echo ":: seeding installer/settings.json into the build (--impure)"
    fi
    if jq -e 'any(.[]; .source.env != null)' "${IH_ASSETS:-/dev/null}" >/dev/null 2>&1; then
        impure=(--impure)
        echo ":: env-sourced secrets detected — building --impure"
    fi
    gum spin --title "Building unattended ISO…" -- \
        nix build "${impure[@]}" "${FLAKE}#installerIso" --print-build-logs
    show_iso
    ;;
  Guided*)
    gum spin --title "Building guided ISO…" -- \
        nix build "${FLAKE}#guidedIso" --print-build-logs
    show_iso
    ;;
  Network*)
    gum style "Run the network installer:" "  nix run ${FLAKE}#deploy -- root@<ip-address>"
    ;;
esac
