#!/usr/bin/env bash
set -euo pipefail
# ════════════════════════════════════════════════════════════════════════════
#  deploy.sh — network install via nixos-anywhere. Workstation-side.
#  Stages secret assets (and, for local style, the seeded /etc/nixos) into a tree
#  and pushes them with --extra-files.
#  Usage:  nix run .#deploy -- root@<ip>
# ════════════════════════════════════════════════════════════════════════════

FLAKE="${IH_FLAKE_REF:-.}"
TARGET="${1:-}"
[ -z "$TARGET" ] && TARGET=$(gum input --header "Target SSH host" --placeholder "root@192.0.2.10")
[ -z "$TARGET" ] && { echo "No target host given."; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# Per-root settings written by configure.sh. A flake only sees git-TRACKED files,
# so untracked ones reach the evaluation by path (IH_SETTINGS_DIR, --impure) —
# the same injection the wizard does for the unattended ISO.
SETTINGS_DIR="${IH_SETTINGS_DIR:-}"
if [ -z "$SETTINGS_DIR" ] && ls installer/*-settings.json >/dev/null 2>&1; then
    SETTINGS_DIR="$(realpath installer)"
fi

# ── Secret assets ────────────────────────────────────────────────────────────
# Stage each declared asset under STAGE mirroring its absolute target path. A
# `required` asset cannot be skipped: without it (the agenix key, typically) the
# machine installs fine and then fails to decrypt every secret on first boot.
while read -r asset; do
    [ -z "$asset" ] && continue
    name=$(jq -r '.name' <<<"$asset")
    target=$(jq -r '.target' <<<"$asset")
    mode=$(jq -r '.mode // "0400"' <<<"$asset")
    env=$(jq -r '.source.env // empty' <<<"$asset")
    file=$(jq -r '.source.file // empty' <<<"$asset")
    required=$(jq -r '.required // false' <<<"$asset")
    dst="${STAGE}${target}"
    mkdir -p "$(dirname "$dst")"

    if [ -n "$env" ] && [ -n "${!env:-}" ]; then
        echo ":: asset ${name} → ${target} (from \$${env})"
        # $(…) strips the trailing newline; a PEM private key needs it back.
        printf '%s\n' "${!env%$'\n'}" > "$dst"
    elif [ -n "$file" ] && [ -e "$file" ]; then
        echo ":: asset ${name} → ${target} (from ${file})"
        cp "$file" "$dst"
    else
        if [ "$required" = "true" ]; then
            gum style --foreground 214 "Required asset '${name}' (→ ${target}) is not set${env:+ — \$${env} is empty}." \
                "Enter the project's devShell (direnv) so it is exported, or provide it now."
            gum confirm "Provide '${name}' now?" || {
                echo "Aborted: '${name}' is required${env:+ (export ${env})}." >&2
                exit 1
            }
        else
            gum confirm "Provide asset '${name}' (→ ${target})?" || { rmdir "$(dirname "$dst")" 2>/dev/null || true; continue; }
        fi
        method=$(gum choose --header "How to provide ${name}?" "Read from a file" "Paste contents")
        if [ "$method" = "Read from a file" ]; then
            cp "$(gum file --header "Select ${name}")" "$dst"
        else
            gum write --header "Paste ${name} (Ctrl+D when done)" > "$dst"
        fi
        if [ "$required" = "true" ] && [ ! -s "$dst" ]; then
            echo "Aborted: '${name}' is required and was left empty." >&2
            exit 1
        fi
    fi
    [ -e "$dst" ] && chmod "$mode" "$dst"
done < <(jq -c '.[]?' "${IH_ASSETS:-/dev/null}" 2>/dev/null || true)

# ── Seed /etc/nixos (local style) ────────────────────────────────────────────
# The same synthesized minimal flake + placeholder module + per-root settings the
# ISO installers seed, so a network-installed machine can `nixos-rebuild` itself.
if [ -n "${IH_LOCAL_FLAKE_NIX:-}" ]; then
    mkdir -p "${STAGE}/etc/nixos"
    install -m 0644 "$IH_LOCAL_FLAKE_NIX" "${STAGE}/etc/nixos/flake.nix"
    [ -n "${IH_LOCAL_MODULE_NIX:-}" ] && install -m 0644 "$IH_LOCAL_MODULE_NIX" "${STAGE}/etc/nixos/local.nix"
    while IFS= read -r root; do
        [ -z "$root" ] && continue
        src="${SETTINGS_DIR}/${root}-settings.json"
        # Root-only: settings can carry bootstrap secrets (an initial password).
        [ -n "$SETTINGS_DIR" ] && [ -f "$src" ] && install -m 0600 "$src" "${STAGE}/etc/nixos/${root}-settings.json"
    done < <(jq -r '.[]?' "${IH_ROOTS:-/dev/null}" 2>/dev/null || true)
    echo ":: seeding /etc/nixos (local flake)"
fi

extra=()
if [ -n "$(find "$STAGE" -type f 2>/dev/null)" ]; then
    extra=(--extra-files "$STAGE")
fi

gum confirm "Install ${FLAKE}#install onto ${TARGET}? This WIPES its disks." || { echo "Aborted."; exit 1; }

# ── Build + install ──────────────────────────────────────────────────────────
# nixos-anywhere evaluates --flake purely and has no --impure, so untracked
# settings would silently fall back to option defaults. With settings present,
# build the disko script and system here (impurely, reading them by path) and hand
# nixos-anywhere the store paths instead.
#
# Not `exec`: the EXIT trap has to run, or the staged tree — the private key
# included — outlives the deploy in /tmp.
if [ -n "$SETTINGS_DIR" ] && ls "$SETTINGS_DIR"/*-settings.json >/dev/null 2>&1; then
    export IH_SETTINGS_DIR="$SETTINGS_DIR"
    echo ":: building with settings from ${SETTINGS_DIR} (--impure)"
    cfg="${FLAKE}#nixosConfigurations.install.config.system.build"
    disko=$(nix build --impure --no-link --print-out-paths "${cfg}.diskoScript")
    toplevel=$(nix build --impure --no-link --print-out-paths "${cfg}.toplevel")
    nixos-anywhere "${extra[@]}" --store-paths "$disko" "$toplevel" --target-host "$TARGET"
    exit $?
fi

nixos-anywhere "${extra[@]}" --flake "${FLAKE}#install" --target-host "$TARGET"
