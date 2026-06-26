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

# ── Build the --extra-files list ─────────────────────────────────────────────
extra_args=()
# Embedded secret assets → their target paths on the installed system.
while IFS=$'\t' read -r name target; do
    [ -z "$name" ] && continue
    src="${ASSET_DIR}/${name}"
    if [ -e "$src" ]; then
        echo ":: asset ${name} → ${target}"
        extra_args+=(--extra-files "$src" "$target")
    fi
done < <(jq -r '.assets[]? | select(.embedded) | [.name, .target] | @tsv' "$MANIFEST")

# Seed /etc/nixos (local style) so the installed host can nixos-rebuild later.
if [ "$FLAKE_STYLE" = "local" ]; then
    for f in flake.nix flake.lock; do
        if [ -e "${FLAKE_DIR}/${f}" ]; then
            extra_args+=(--extra-files "${FLAKE_DIR}/${f}" "etc/nixos/${f}")
        fi
    done
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
