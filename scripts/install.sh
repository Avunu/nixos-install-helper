#!/usr/bin/env bash
set -euo pipefail
# ════════════════════════════════════════════════════════════════════════════
#  install.sh — pick a deployment path and build/launch it. Workstation-side.
# ════════════════════════════════════════════════════════════════════════════

FLAKE="${IH_FLAKE_REF:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-flash.sh
source "${SCRIPT_DIR}/lib-flash.sh"

# The last step of every ISO build is one mksquashfs pass over the whole offline
# closure, and mksquashfs suppresses its progress bar whenever stdout is not a
# tty — which under `nix build` it never is. So the build goes completely silent
# after "Creating 4.0 filesystem on nix-store.squashfs" for as long as that pass
# takes (minutes, on a multi-GB closure), and looks hung. Say so up front.
squashfs_note() {
    gum style --faint \
        "The build ends with a single mksquashfs pass over the whole offline closure." \
        "mksquashfs prints nothing to a non-tty, so the log stops at \"Creating 4.0" \
        "filesystem on nix-store.squashfs\" and stays there for several minutes." \
        "That is the compression running, not a hang — watch CPU if in doubt."
}

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
    squashfs_note
    if ! nix build "${impure[@]}" "${FLAKE}#installerIso" --print-build-logs; then
        gum style --foreground 196 "Unattended ISO build FAILED — see the log above."
        exit 1
    fi
    show_iso
    ;;
  Guided*)
    gum style --foreground 212 "Building guided ISO… (build logs below)"
    squashfs_note
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
