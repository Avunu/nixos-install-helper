#!/usr/bin/env bash
set -euo pipefail
# ════════════════════════════════════════════════════════════════════════════
#  deploy.sh — network install via nixos-anywhere. Workstation-side.
#  Stages secret assets (and, for local style, the seeded /etc/nixos) into a tree
#  and pushes them with --extra-files.
#  Usage:  nix run .#deploy -- root@<ip> [nixos-anywhere arguments…]
#
#  Everything after the target is handed to nixos-anywhere as it is: -i <key>,
#  --ssh-option, --kexec <tarball>, --build-on, …
#
#  Environment a caller may set (an operations tool driving this, a test):
#    IH_ASSUME_YES=1     do not ask before wiping: the caller already did.
#    IH_STORE_PATHS      "<disko script> <toplevel>", already built: install
#                        these instead of evaluating the flake.
#
#  With a pre-install hook (mkProject `preInstall`, IH_PRE_INSTALL) the install
#  is two nixos-anywhere runs with the hook between them: `--phases kexec`, the
#  hook, then `--phases disko,install,reboot`. The hook runs here, on the
#  workstation, in the project's working tree, with:
#    IH_TARGET           the SSH target, now running the NixOS installer
#    IH_HOST_ATTR        the flake attribute being installed
#    IH_EXTRA_FILES      a directory copied onto the installed system
#                        (--extra-files): write <dir>/<absolute path> to add one
#    IH_DISK_KEYS        a directory on a tmpfs, never copied to the installed
#                        system: each <dir>/<absolute path> in it is put at
#                        <absolute path> on the installer before partitioning
#                        (--disk-encryption-keys), where disko and its hooks
#                        read it, and is gone at the reboot.
#  The flake is evaluated for the system only after the hook returns, so what
#  the hook writes into the working tree (and `git add`s) is part of what is
#  installed. A hook that fails stops the install with the disks untouched.
# ════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-flake.sh
source "${SCRIPT_DIR}/lib-flake.sh"
# shellcheck source=lib-assets.sh
source "${SCRIPT_DIR}/lib-assets.sh"
FLAKE="$(resolve_flake)"
load_age_assets
TARGET="${1:-}"
[ -z "$TARGET" ] && TARGET=$(gum input --header "Target SSH host" --placeholder "root@192.0.2.10")
[ -z "$TARGET" ] && { echo "No target host given."; exit 1; }
# What follows the target is nixos-anywhere's.
passthrough=()
[ "$#" -gt 1 ] && passthrough=("${@:2}")
HOST_ATTR="${IH_HOST_ATTR:-install}"

STAGE=$(mktemp -d)
# Disk secrets wait here between the hook and the upload, so in memory when the
# machine has a tmpfs to offer, and under a directory only this user can enter.
KEYS=""
for base in "${XDG_RUNTIME_DIR:-}" /dev/shm; do
    if [ -n "$base" ] && [ -d "$base" ] && [ -w "$base" ]; then
        KEYS=$(mktemp -d -p "$base" ih-disk-keys.XXXXXX)
        break
    fi
done
[ -n "$KEYS" ] || KEYS=$(mktemp -d)
trap 'rm -rf "$STAGE" "$KEYS"' EXIT

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

if [ "${IH_ASSUME_YES:-0}" != "1" ]; then
    gum confirm "Install ${FLAKE}#${HOST_ATTR} onto ${TARGET}? This WIPES its disks." || { echo "Aborted."; exit 1; }
fi

# ── Pre-install hook ─────────────────────────────────────────────────────────
# Into the installer first, then the hook, then everything else. The phases
# below are what is left for the install proper.
phases=()
if [ -n "${IH_PRE_INSTALL:-}" ]; then
    echo ":: booting the installer on ${TARGET} (kexec)"
    # nixos-anywhere wants to be told what it would install even when asked for
    # the kexec alone. It builds neither: that is the second run's, after the hook.
    if [ -n "${IH_STORE_PATHS:-}" ]; then
        # shellcheck disable=SC2086  # two paths, split on purpose
        what=(--store-paths $IH_STORE_PATHS)
    else
        what=(--flake "${FLAKE}#${HOST_ATTR}")
    fi
    nixos-anywhere --phases kexec "${passthrough[@]}" "${what[@]}" --target-host "$TARGET"
    echo ":: pre-install hook"
    IH_TARGET="$TARGET" IH_HOST_ATTR="$HOST_ATTR" IH_EXTRA_FILES="$STAGE" IH_DISK_KEYS="$KEYS" \
        "$IH_PRE_INSTALL" || { echo "Aborted: the pre-install hook failed. Nothing was partitioned." >&2; exit 1; }
    phases=(--phases "disko,install,reboot")
    # The hook may have staged files of its own.
    if [ -n "$(find "$STAGE" -type f 2>/dev/null)" ]; then
        extra=(--extra-files "$STAGE")
    fi
fi

# Each file the hook left under KEYS goes to the same path on the installer.
disk_keys=()
while IFS= read -r -d '' f; do
    disk_keys+=(--disk-encryption-keys "/${f#"$KEYS"/}" "$f")
done < <(find "$KEYS" -type f -print0 2>/dev/null)

# ── Build + install ──────────────────────────────────────────────────────────
# nixos-anywhere evaluates --flake purely and has no --impure, so untracked
# settings would silently fall back to option defaults. With settings present,
# build the disko script and system here (impurely, reading them by path) and hand
# nixos-anywhere the store paths instead.
#
# Not `exec`: the EXIT trap has to run, or the staged tree — the private key
# included — outlives the deploy in /tmp.
common=("${phases[@]}" "${extra[@]}" "${disk_keys[@]}" "${passthrough[@]}")

if [ -n "${IH_STORE_PATHS:-}" ]; then
    # shellcheck disable=SC2086  # two paths, split on purpose
    nixos-anywhere "${common[@]}" --store-paths $IH_STORE_PATHS --target-host "$TARGET"
    exit $?
fi

if [ -n "$SETTINGS_DIR" ] && ls "$SETTINGS_DIR"/*-settings.json >/dev/null 2>&1; then
    export IH_SETTINGS_DIR="$SETTINGS_DIR"
    echo ":: building with settings from ${SETTINGS_DIR} (--impure)"
    cfg="${FLAKE}#nixosConfigurations.${HOST_ATTR}.config.system.build"
    disko=$(nix build --impure --no-link --print-out-paths "${cfg}.diskoScript")
    toplevel=$(nix build --impure --no-link --print-out-paths "${cfg}.toplevel")
    nixos-anywhere "${common[@]}" --store-paths "$disko" "$toplevel" --target-host "$TARGET"
    exit $?
fi

nixos-anywhere "${common[@]}" --flake "${FLAKE}#${HOST_ATTR}" --target-host "$TARGET"
