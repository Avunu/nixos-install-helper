#!/usr/bin/env bash
set -euo pipefail
# ════════════════════════════════════════════════════════════════════════════
#  install.sh — pick a deployment path and build/launch it. Workstation-side.
# ════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-flash.sh
source "${SCRIPT_DIR}/lib-flash.sh"
# shellcheck source=lib-flake.sh
source "${SCRIPT_DIR}/lib-flake.sh"
# shellcheck source=lib-assets.sh
source "${SCRIPT_DIR}/lib-assets.sh"
# shellcheck source=lib-build.sh
source "${SCRIPT_DIR}/lib-build.sh"
FLAKE="$(resolve_flake)"
load_age_assets

install_choices=("Unattended ISO  (pre-seeded, per-host, installs with no interaction)")
[ "${IH_GUIDED:-1}" = "1" ] && install_choices+=("Guided ISO      (generic, boots into the menu, choose identity on the box)")
install_choices+=("Network install (nixos-anywhere over SSH to a reachable target)")
choice=$(gum choose --header "Deployment path:" "${install_choices[@]}")

impure=()
case "$choice" in
  Unattended*)
    prepare_unattended_build || exit 1
    build_iso installerIso || exit 1
    show_iso
    ;;
  Guided*)
    build_iso guidedIso || exit 1
    show_iso
    ;;
  Network*)
    gum style "Run the network installer:" "  nix run ${FLAKE}#deploy -- root@<ip-address>"
    ;;
esac
