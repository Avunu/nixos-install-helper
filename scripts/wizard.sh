#!/usr/bin/env bash
set -euo pipefail
# ════════════════════════════════════════════════════════════════════════════
#  wizard.sh — the single entrypoint (`nix run .#` / `nix run github:Owner/repo`).
#  Walks the technician through: (optionally) collecting settings, then choosing a
#  deployment path — network install, unattended ISO, or guided ISO.
# ════════════════════════════════════════════════════════════════════════════

FLAKE="${IH_FLAKE_REF:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-flash.sh
source "${SCRIPT_DIR}/lib-flash.sh"

gum style --border double --padding "1 2" --border-foreground 212 \
    "nixos-install-helper" "Guided deployment wizard"

# ── 1. Settings (only when this project exposes install-time options) ────────
# configure.sh writes FLAT per-root files: installer/<root>-settings.json.
if [ "${IH_HAS_SETTINGS:-0}" = "1" ]; then
    if ! ls installer/*-settings.json >/dev/null 2>&1; then
        gum style "No installer settings yet — let's create them."
        bash "${SCRIPT_DIR}/configure.sh" "installer/settings.json"
    elif gum confirm "Reconfigure installer settings?" --default=false; then
        bash "${SCRIPT_DIR}/configure.sh" "installer/settings.json"
    fi
fi

# ── 2. Deployment path ───────────────────────────────────────────────────────
deploy_choices=(
    "Network install  (nixos-anywhere over SSH — no USB)"
    "Unattended ISO   (pre-seeded, installs with no interaction)"
)
# Guided ISO is only offered when the project builds one (guided != false).
[ "${IH_GUIDED:-1}" = "1" ] && deploy_choices+=("Guided ISO       (generic, choose identity on the target box)")
choice=$(gum choose --header "How do you want to deploy?" "${deploy_choices[@]}")

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

# Impure build triggers (builtins.getEnv): env-sourced secrets, and the untracked
# per-root settings files (flakes ignore untracked files, so the dir is injected
# by path via IH_SETTINGS_DIR).
impure=()
if [ "${allow_impure}" = "1" ]; then
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
fi

# Build in the foreground with live logs — a `gum spin` wrapper here would hide
# the build output, so an evaluation/assertion failure looks like a silent exit
# ("no error, no ISO") instead of showing the actual cause.
gum style --foreground 212 "Building ${attr}… (build logs below)"
# …and the last step of that build is one mksquashfs pass over the whole offline
# closure. mksquashfs suppresses its progress bar when stdout is not a tty (under
# `nix build` it never is), so the log stops dead after "Creating 4.0 filesystem
# on nix-store.squashfs" for as long as the pass takes. Set expectations, or it
# reads as a hang.
gum style --faint \
    "The build ends with a single mksquashfs pass over the whole offline closure." \
    "mksquashfs prints nothing to a non-tty, so the log stops at \"Creating 4.0" \
    "filesystem on nix-store.squashfs\" and stays there for several minutes." \
    "That is the compression running, not a hang — watch CPU if in doubt."
if ! nix build "${impure[@]}" "${FLAKE}#${attr}" --print-build-logs; then
    gum style --foreground 196 "Build of ${attr} FAILED — see the log above for the cause."
    exit 1
fi

iso=$(find -L result/iso -name '*.iso' 2>/dev/null | head -1)
if [ -n "$iso" ]; then
    gum style --foreground 42 "ISO: $iso"
    flash_iso "$iso"
    echo "  Flash manually:  sudo dd if=\"$iso\" of=/dev/sdX bs=4M status=progress conv=fsync"
    echo "  Or boot it directly in a VM to test the install."
else
    echo "Build finished but no ISO was found under ./result/iso" >&2
fi
