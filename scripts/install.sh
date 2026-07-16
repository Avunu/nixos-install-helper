#!/usr/bin/env bash
set -euo pipefail
# ════════════════════════════════════════════════════════════════════════════
#  install.sh — pick a deployment path and build/launch it. Workstation-side.
# ════════════════════════════════════════════════════════════════════════════

FLAKE="${IH_FLAKE_REF:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-flash.sh
source "${SCRIPT_DIR}/lib-flash.sh"

show_iso() {
    local iso
    iso=$(find -L result/iso -name '*.iso' 2>/dev/null | head -1)
    if [ -n "$iso" ]; then
        gum style --foreground 42 "ISO: $iso"
        flash_iso "$iso"
        echo "  Flash manually:  sudo dd if=\"$iso\" of=/dev/sdX bs=4M status=progress conv=fsync"
    else
        echo "Build finished but no ISO found under ./result/iso" >&2
    fi
}

install_choices=("Unattended ISO  (pre-seeded, per-host, installs with no interaction)")
[ "${IH_GUIDED:-1}" = "1" ] && install_choices+=("Guided ISO      (generic, boots into the menu, choose identity on the box)")
install_choices+=("Network install (nixos-anywhere over SSH to a reachable target)")
choice=$(gum choose --header "Deployment path:" "${install_choices[@]}")

case "$choice" in
  Unattended*)
    # Impure build triggers (builtins.getEnv): env-sourced secrets, and the untracked
    # per-root settings files (flakes ignore untracked files → inject the dir by path).
    impure=()
    if ls installer/*-settings.json >/dev/null 2>&1; then
        impure=(--impure)
        IH_SETTINGS_DIR="$(realpath installer)"
        export IH_SETTINGS_DIR
        echo ":: seeding installer/ settings into the build (--impure)"
    fi
    if jq -e 'any(.[]; .source.env != null)' "${IH_ASSETS:-/dev/null}" >/dev/null 2>&1; then
        impure=(--impure)
        echo ":: env-sourced secrets detected — building --impure"
    fi
    # Foreground build with live logs — see the wizard.sh note: a spinner would
    # hide an eval/assertion failure and make it look like a silent no-op.
    gum style --foreground 212 "Building unattended ISO… (build logs below)"
    if ! nix build "${impure[@]}" "${FLAKE}#installerIso" --print-build-logs; then
        gum style --foreground 196 "Unattended ISO build FAILED — see the log above."
        exit 1
    fi
    show_iso
    ;;
  Guided*)
    gum style --foreground 212 "Building guided ISO… (build logs below)"
    if ! nix build "${FLAKE}#guidedIso" --print-build-logs; then
        gum style --foreground 196 "Guided ISO build FAILED — see the log above."
        exit 1
    fi
    show_iso
    ;;
  Network*)
    gum style "Run the network installer:" "  nix run ${FLAKE}#deploy -- root@<ip-address>"
    ;;
esac
