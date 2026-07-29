#!/usr/bin/env bash
set -euo pipefail
# ════════════════════════════════════════════════════════════════════════════
#  Unattended NixOS install via disko-install (offline). Runs as the tty1 console
#  session on the installer ISO. Partitions + formats + installs by re-evaluating
#  the self-contained flake at /etc/installer-flake; every input and the prebuilt
#  system closure are baked into the ISO, so it runs WITHOUT network.
#
#  All parameters come from /etc/installer-manifest.json (written by mk-project).
#  Generalized from nixos-router's unattended-install.sh.
# ════════════════════════════════════════════════════════════════════════════

MANIFEST=/etc/installer-manifest.json
FLAKE_DIR=/etc/installer-flake
ASSET_DIR=/etc/installer-assets
LOG=/tmp/install-helper.log

# disko-install re-evaluates ${FLAKE_DIR}#install with --impure. The technician's
# per-root settings files are NOT in the shipped flake (untracked files aren't in
# `self`), so without this the re-eval would read empty settings and rebuild a
# DIFFERENT system online. Point IH_SETTINGS_DIR at the settings baked alongside the
# ISO so the re-eval reproduces the exact toplevel already in the offline closure.
if [ -d /etc/installer-settings ]; then
    export IH_SETTINGS_DIR=/etc/installer-settings
fi

HOST_ATTR=$(jq -r '.hostAttr' "$MANIFEST")
DISK_NAME=$(jq -r '.diskName // "main"' "$MANIFEST")
DISK_DEVICE=$(jq -r '.diskDevice // ""' "$MANIFEST")
FLAKE_STYLE=$(jq -r '.flakeStyle // "local"' "$MANIFEST")

wait_for_enter() {
    local msg="$1" timeout="$2" prompt="$3"
    [ -n "$msg" ] && echo "$msg"
    for i in $(seq "$timeout" -1 1); do
        printf "\r  %2d s — %s " "$i" "$prompt"
        if read -r -t 1; then echo ""; return 0; fi
    done
    echo ""
    return 1
}

echo "=============================================="
echo " AUTOMATED NIXOS INSTALL (disko-install)"
echo " Host attr : ${HOST_ATTR}"
echo " Disk      : ${DISK_DEVICE}  (ALL DATA WILL BE WIPED)"
echo " Style     : ${FLAKE_STYLE}"
echo " Log       : ${LOG}  (also on Alt+F2 … F6)"
echo "=============================================="

if [ -z "$DISK_DEVICE" ]; then
    echo "ERROR: no diskDevice in the manifest. This ISO needs a per-host device."
    exit 1
fi
if [ ! -b "$DISK_DEVICE" ]; then
    echo "ERROR: target disk ${DISK_DEVICE} is not a block device."
    exit 1
fi

# ── Safety: existing-installation detection (label + bootloader probe) ───────
if [ -b "/dev/disk/by-label/ESP" ] || [ -b "/dev/disk/by-label/boot" ] || [ -b "/dev/disk/by-label/root" ]; then
    HAVE_LOADER=0
    mkdir -p /tmp/probe-boot
    for lbl in ESP boot; do
        if [ -b "/dev/disk/by-label/$lbl" ] && mount -o ro "/dev/disk/by-label/$lbl" /tmp/probe-boot 2>/dev/null; then
            [ -f /tmp/probe-boot/EFI/systemd/systemd-bootx64.efi ] && HAVE_LOADER=1
            [ -f /tmp/probe-boot/EFI/BOOT/BOOTX64.EFI ] && HAVE_LOADER=1
            [ -d /tmp/probe-boot/loader ] && HAVE_LOADER=1
            [ -d /tmp/probe-boot/grub ] && HAVE_LOADER=1
            umount /tmp/probe-boot 2>/dev/null || true
        fi
    done
    if [ "$HAVE_LOADER" = "1" ]; then
        echo ""
        echo "  Existing installation with bootloader detected on ${DISK_DEVICE}."
        if ! wait_for_enter "  Press Enter within 10 s to WIPE and force a fresh install." 10 \
            "press Enter to force fresh install, or wait to resume normal boot..."; then
            echo "No input — resuming normal boot."
            exit 0
        fi
    else
        wait_for_enter "  Labels found but no bootloader — installing in 10 s." 10 \
            "press Enter to install now, Ctrl+C to abort..." || true
    fi
else
    echo "No existing installation detected."
    wait_for_enter "  Installing in 10 s — press Ctrl+C to abort." 10 \
        "press Enter to install now, Ctrl+C to abort..." || true
fi

# ── EFI vs legacy ────────────────────────────────────────────────────────────
efi_args=()
if [ -d /sys/firmware/efi ]; then
    echo ":: UEFI firmware detected — EFI boot entries will be written."
    efi_args+=(--write-efi-boot-entries)
else
    echo ":: Legacy/BIOS firmware detected."
fi

# disko-install copies --extra-files with `cp -a`, which PRESERVES symlinks. Every
# source below lives in the installer's /etc as an environment.etc symlink into
# /etc/static → the Nix store — paths that DON'T exist on the installed target, so a
# copied symlink would dangle. Dereference each to a real temp file (fixing its mode)
# and hand THAT to --extra-files so the target gets real file content.
deref_file() {
    local out
    out=$(mktemp)
    cp -L "$1" "$out"
    [ -n "${2:-}" ] && chmod "$2" "$out"
    printf '%s' "$out"
}

# ── Build the --extra-files list ─────────────────────────────────────────────
extra_args=()
# Embedded secret assets → their target paths on the installed system.
while IFS=$'\t' read -r name target mode; do
    [ -z "$name" ] && continue
    src="${ASSET_DIR}/${name}"
    if [ -e "$src" ]; then
        echo ":: asset ${name} → ${target}"
        extra_args+=(--extra-files "$(deref_file "$src" "${mode:-0400}")" "$target")
    fi
done < <(jq -r '.assets[]? | select(.embedded) | [.name, .target, (.mode // "0400")] | @tsv' "$MANIFEST")

# Seed /etc/nixos (local style) with the SYNTHESIZED minimal flake + the FLAT per-root
# <root>-settings.json files (each scoped under its option root by the flake) — rather
# than a verbatim copy of the whole project source. No first-boot reconcile marker:
# the baked system is already complete (agenix secrets activate at boot regardless).
if [ "$FLAKE_STYLE" = "local" ] && [ -f /etc/installer-local-flake/flake.nix ]; then
    extra_args+=(--extra-files "$(deref_file /etc/installer-local-flake/flake.nix 0644)" "etc/nixos/flake.nix")
    # Placeholder machine-local module the flake imports (extra packages / any
    # NixOS config the typed JSON settings cannot express). Empty but annotated.
    if [ -f /etc/installer-local-flake/local.nix ]; then
        extra_args+=(--extra-files "$(deref_file /etc/installer-local-flake/local.nix 0644)" "etc/nixos/local.nix")
    fi
    while IFS= read -r root; do
        [ -z "$root" ] && continue
        src="/etc/installer-settings/${root}-settings.json"
        [ -f "$src" ] && extra_args+=(--extra-files "$(deref_file "$src" 0644)" "etc/nixos/${root}-settings.json")
    done < <(jq -r '.roots[]?' "$MANIFEST")
fi

echo ":: Starting disko-install (offline)…"
if disko-install \
    --flake "${FLAKE_DIR}#${HOST_ATTR}" \
    --disk "${DISK_NAME}" "${DISK_DEVICE}" \
    "${efi_args[@]}" \
    "${extra_args[@]}" \
    2>&1 | tee "$LOG"; then
    echo "=============================================="
    echo " Installation complete! Rebooting in 5 s…"
    echo "=============================================="
    sleep 5
    reboot
else
    echo ""
    echo " INSTALLATION FAILED — full log: ${LOG}"
    echo " Opening pager (q to quit). Other consoles: Alt+F2 … F6."
    sleep 3
    less "$LOG" || true
    echo " Dropping to a root shell for debugging."
    exec bash -i
fi
