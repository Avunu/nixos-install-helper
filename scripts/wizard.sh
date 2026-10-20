#!/usr/bin/env bash
set -euo pipefail
# ════════════════════════════════════════════════════════════════════════════
#  wizard.sh — the single entrypoint (`nix run .#` / `nix run github:Owner/repo`).
#  Walks the technician through: (optionally) collecting settings, (in a
#  directory that is not a project yet) creating the machine's repository, then
#  choosing a deployment path — network install, unattended ISO, or guided ISO.
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

gum style --border double --padding "1 2" --border-foreground 212 \
    "nixos-install-helper" "Guided deployment wizard"

# ── 1. Settings (only when this project exposes install-time options) ────────
# configure.sh writes FLAT per-root files: installer/<root>-settings.json. A
# project whose settings are tracked files (a host repo) is already configured.
if [ "${IH_HAS_SETTINGS:-0}" = "1" ] && [ "${IH_SETTINGS_TRACKED:-0}" != "1" ]; then
    if ! ls installer/*-settings.json >/dev/null 2>&1; then
        gum style "No installer settings yet — let's create them."
        bash "${SCRIPT_DIR}/configure.sh" "installer/settings.json"
    elif gum confirm "Reconfigure installer settings?" --default=false; then
        bash "${SCRIPT_DIR}/configure.sh" "installer/settings.json"
    fi
fi

# ── 2. A repository for this machine (empty directory, project opted in) ─────
# Without one, everything below builds the generic template this app shipped
# from, which works but leaves the machine with no configuration of its own to
# keep changing. The project's bootstrap program writes the repository into the
# cwd; we then hand over to THAT repository's own wizard rather than carry on
# here, because only it knows its own assets (an agenix key kept in the repo, say)
# and its own flake style — this process was built from the template.
if ! flake_in_cwd && [ -n "${IH_BOOTSTRAP:-}" ]; then
    bootstrap_choice=$(gum choose --header "This directory is not a project yet." \
        "Create a GitHub-managed repository here  (the machine tracks it)" \
        "Continue without one  (build from the generic template)")
    case "$bootstrap_choice" in
      Create*)
        "$IH_BOOTSTRAP" || { gum style --foreground 196 "Bootstrap did not finish — nothing was installed."; exit 1; }
        exec nix run .
        ;;
    esac
fi

# ── 3. Deployment path ───────────────────────────────────────────────────────
deploy_choices=(
    "Network install  (nixos-anywhere over SSH — no USB)"
    "Unattended ISO   (pre-seeded, installs with no interaction)"
)
# Guided ISO is only offered when the project builds one (guided != false).
[ "${IH_GUIDED:-1}" = "1" ] && deploy_choices+=("Guided ISO       (generic, choose identity on the target box)")
choice=$(gum choose --header "How do you want to deploy?" "${deploy_choices[@]}")

impure=()
case "$choice" in
  Network*)
    exec bash "${SCRIPT_DIR}/deploy.sh" "$@"
    ;;
  Unattended*)
    attr="installerIso"
    prepare_unattended_build || exit 1
    ;;
  Guided*)
    attr="guidedIso"
    ;;
  *)
    echo "Nothing selected."; exit 1 ;;
esac

build_iso "$attr" || exit 1
show_iso
