#!/usr/bin/env bash
set -euo pipefail
# ════════════════════════════════════════════════════════════════════════════
#  Guided NixOS install (offline) — runs as the tty1 console session on a generic
#  guided ISO. Installs the prebuilt TEMPLATE system offline, then seeds the
#  technician's identity so the first-boot reconcile (install-helper-reconcile)
#  applies it. Scope is identity / disk / secrets only — feature toggles are
#  fixed in the template, guaranteeing a fully-offline install.
# ════════════════════════════════════════════════════════════════════════════

MANIFEST=/etc/installer-manifest.json
FLAKE_DIR=/etc/installer-flake

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-preflight.sh
source "${SCRIPT_DIR}/lib-preflight.sh"

HOST_ATTR=$(jq -r '.hostAttr // "installTemplate"' "$MANIFEST")
DISK_NAME=$(jq -r '.diskName // "main"' "$MANIFEST")
FLAKE_STYLE=$(jq -r '.flakeStyle // "local"' "$MANIFEST")
# The mount point the BAKED diskoScript was built for — disko writes it inside
# the script. Left to itself disko-install would use /mnt/disko-install-root and
# build a second copy of a script the ISO already carries, which on an appliance
# with no stdenv is a fetch from gnu.org. See mk-installer-iso.nix.
ROOT_MOUNT_POINT=$(jq -r '.rootMountPoint // "/mnt"' "$MANIFEST")

# ── Preseeding ───────────────────────────────────────────────────────────────
# Everything below is a gum prompt because a guided install is a conversation
# with a technician. IH_NONINTERACTIVE turns the same script into a scripted
# one, taking the answers from the environment instead:
#
#   IH_DISK_DEVICE=/dev/vda     the target disk (required)
#   IH_ANSWERS=<file.json>      answers to the manifest's `prompts`, nested the
#                               way the keys' dotted paths imply
#   IH_ASSETS_DIR=<dir>         per-asset contents as <dir>/<name>; anything
#                               absent is skipped
#
# It also changes what a failure does: an interactive install drops to a shell
# on the console, which for anything driving this script is a hang. Here it is
# the offline-install VM test (lib/mk-offline-install-test.nix), and the same
# contract is what makes a preseeded USB install possible.
NONINTERACTIVE=${IH_NONINTERACTIVE:-}

die_or_shell() {
    if [ -n "$NONINTERACTIVE" ]; then exit 1; fi
    sleep 3
    exec bash -i
}

gum style --border double --margin "1" --padding "1 2" --border-foreground 212 \
    "NixOS Guided Installer" "Identity + disk selection, then an offline install."

# ── Disk selection ───────────────────────────────────────────────────────────
if [ -n "$NONINTERACTIVE" ]; then
    DISK_DEVICE=${IH_DISK_DEVICE:?IH_NONINTERACTIVE needs IH_DISK_DEVICE}
else
    mapfile -t DISKS < <(lsblk -dn -o NAME,SIZE,MODEL | awk '{printf "/dev/%s\t%s %s\n",$1,$2,$3}')
    if [ "${#DISKS[@]}" -eq 0 ]; then
        echo "ERROR: no disks found."; exit 1
    fi
    DISK_LINE=$(printf '%s\n' "${DISKS[@]}" | gum choose --header "Target disk (ALL DATA WIPED):")
    DISK_DEVICE=$(printf '%s' "$DISK_LINE" | cut -f1)
fi
if [ ! -b "$DISK_DEVICE" ]; then
    echo "ERROR: target disk ${DISK_DEVICE} is not a block device."; exit 1
fi

# ── Per-machine settings ─────────────────────────────────────────────────────
# Which questions to ask is the PROJECT's call, not this script's: the manifest's
# `prompts` list is mkProject's `guidedPrompts`, resolved against the project's own
# option schema for each prompt's text and default. Nothing here is hardcoded, so a
# project that asks for a hostname and a username gets both, and one that asks for
# neither is not interrogated about options it does not have.
#
# Keys are dotted paths under the primary option root, so `setpath` — not a flat
# assignment — is what writes `user.name` as nested JSON the way the option tree
# expects it.
ANSWERS=$(mktemp)
echo '{}' > "$ANSWERS"
SUMMARY=()
while IFS=$'\t' read -r key prompt def; do
    [ -z "$key" ] && continue
    if [ -n "$NONINTERACTIVE" ]; then
        # Preseeded: take the answer from IH_ANSWERS if it carries this key,
        # otherwise the option's own default — the same value pressing Enter
        # at the prompt would have accepted.
        val=$(jq -r --arg k "$key" --arg d "$def" \
            'getpath($k | split(".")) // $d | tostring' "${IH_ANSWERS:-/dev/null}" 2>/dev/null || echo "$def")
    else
        val=$(gum input --header "$prompt" --placeholder "$def" --value "$def")
    fi
    val=${val:-$def}
    jq --arg k "$key" --arg v "$val" 'setpath($k | split("."); $v)' "$ANSWERS" > "${ANSWERS}.tmp"
    mv "${ANSWERS}.tmp" "$ANSWERS"
    SUMMARY+=("${key}: ${val}")
done < <(jq -r '.prompts[]? | [.key, .prompt, (.default // "")] | @tsv' "$MANIFEST")

# ── Secret assets (provided at install time; ISO stays generic) ──────────────
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
extra_args=()
while IFS=$'\t' read -r name target mode; do
    [ -z "$name" ] && continue
    dst="${STAGE}/${name}"
    if [ -n "$NONINTERACTIVE" ]; then
        src="${IH_ASSETS_DIR:-/nonexistent}/${name}"
        [ -e "$src" ] || continue
        cp "$src" "$dst"
    else
        gum confirm "Provide asset '${name}' (→ ${target})?" || continue
        method=$(gum choose --header "How to provide ${name}?" "Read from a file" "Paste contents")
        if [ "$method" = "Read from a file" ]; then
            src=$(gum file --header "Select ${name}")
            cp "$src" "$dst"
        else
            gum write --header "Paste ${name} (Ctrl+D when done)" > "$dst"
        fi
    fi
    chmod "${mode:-0400}" "$dst"
    extra_args+=(--extra-files "$dst" "$target")
done < <(jq -r '.assets[]? | [.name, .target, (.mode // "0400")] | @tsv' "$MANIFEST")

# ── Confirm ──────────────────────────────────────────────────────────────────
gum style --border normal --padding "0 1" \
    "Disk:  ${DISK_DEVICE}" "${SUMMARY[@]}" "Style: ${FLAKE_STYLE}"
if [ -z "$NONINTERACTIVE" ]; then
    gum confirm "Proceed with the install? This WIPES ${DISK_DEVICE}." || { echo "Aborted."; exit 1; }
fi

# ── EFI vs legacy ────────────────────────────────────────────────────────────
efi_args=()
[ -d /sys/firmware/efi ] && efi_args+=(--write-efi-boot-entries)

# ── Seed: synthesized local flake + chosen identity so first boot applies it ──
# The synthesized /etc/nixos/flake.nix reads FLAT per-root <root>-settings.json; the
# answers collected above ARE that file's contents (closure-safe keys only). Fall
# back to a bare settings.json if the project declares no roots.
SETTINGS="$ANSWERS"
PRIMARY_ROOT=$(jq -r '.primaryRoot // ""' "$MANIFEST")
# mktemp is 0600 and disko-install's `cp -a` preserves it. This is the file the
# machine's owner (and Cockpit, where a project ships one) edits to change any of
# these settings later, so it lands 0644 like the flake beside it.
chmod 0644 "$SETTINGS"

if [ "$FLAKE_STYLE" = "local" ] && [ -f /etc/installer-local-flake/flake.nix ]; then
    # /etc/installer-local-flake/flake.nix is an environment.etc symlink into
    # /etc/static; disko-install's `cp -a` would copy it as a dangling symlink, so
    # dereference to a real file first. ($SETTINGS/$MARKER are already real files.)
    FLAKE_REAL=$(mktemp)
    cp -L /etc/installer-local-flake/flake.nix "$FLAKE_REAL"
    # mktemp is 0600 and disko-install's `cp -a` preserves it; these are the
    # files the machine's owner edits, so land them 0644 like the unattended path.
    chmod 0644 "$FLAKE_REAL"
    extra_args+=(--extra-files "$FLAKE_REAL" "etc/nixos/flake.nix")
    # Placeholder machine-local module the flake imports (extra packages / any
    # NixOS config the typed JSON settings cannot express). Empty but annotated.
    if [ -f /etc/installer-local-flake/local.nix ]; then
        LOCAL_REAL=$(mktemp)
        cp -L /etc/installer-local-flake/local.nix "$LOCAL_REAL"
        chmod 0644 "$LOCAL_REAL"
        extra_args+=(--extra-files "$LOCAL_REAL" "etc/nixos/local.nix")
    fi
    if [ -n "$PRIMARY_ROOT" ]; then
        extra_args+=(--extra-files "$SETTINGS" "etc/nixos/${PRIMARY_ROOT}-settings.json")
    else
        extra_args+=(--extra-files "$SETTINGS" "etc/nixos/settings.json")
    fi
    # The guided template boots with a generic identity; drop a marker so the
    # first-boot reconcile rebuilds /etc/nixos#default and applies the chosen host.
    MARKER=$(mktemp)
    extra_args+=(--extra-files "$MARKER" "etc/nixos/.first-boot-reconcile")
fi

# Prove the closure covers this machine before anything is destroyed. The guided
# path needs this more than the unattended one: the disk is chosen here, on the
# box, so it is an input the ISO could not have been baked against. See
# lib-preflight.sh.
if ! preflight_offline "$FLAKE_DIR" "$HOST_ATTR" "$DISK_NAME" "$DISK_DEVICE" \
        "$([ -d /sys/firmware/efi ] && echo true || echo false)" "$ROOT_MOUNT_POINT"; then
    die_or_shell
fi

echo ":: Installing template offline…"
LOG=/tmp/install-helper.log
if disko-install \
    --flake "${FLAKE_DIR}#${HOST_ATTR}" \
    --disk "${DISK_NAME}" "${DISK_DEVICE}" \
    --mount-point "${ROOT_MOUNT_POINT}" \
    "${efi_args[@]}" \
    "${extra_args[@]}" \
    2>&1 | tee "$LOG"; then
    gum style --foreground 42 "Install complete — rebooting; identity is applied on first boot."
    sleep 5
    reboot
else
    echo "INSTALL FAILED — log: ${LOG}"
    if [ -z "$NONINTERACTIVE" ]; then
        sleep 3
        less "$LOG" || true
    fi
    die_or_shell
fi
