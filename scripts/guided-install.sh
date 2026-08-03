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

HOST_ATTR=$(jq -r '.hostAttr // "installTemplate"' "$MANIFEST")
DISK_NAME=$(jq -r '.diskName // "main"' "$MANIFEST")
FLAKE_STYLE=$(jq -r '.flakeStyle // "local"' "$MANIFEST")

gum style --border double --margin "1" --padding "1 2" --border-foreground 212 \
    "NixOS Guided Installer" "Identity + disk selection, then an offline install."

# ── Disk selection ───────────────────────────────────────────────────────────
mapfile -t DISKS < <(lsblk -dn -o NAME,SIZE,MODEL | awk '{printf "/dev/%s\t%s %s\n",$1,$2,$3}')
if [ "${#DISKS[@]}" -eq 0 ]; then
    echo "ERROR: no disks found."; exit 1
fi
DISK_LINE=$(printf '%s\n' "${DISKS[@]}" | gum choose --header "Target disk (ALL DATA WIPED):")
DISK_DEVICE=$(printf '%s' "$DISK_LINE" | cut -f1)

# ── Identity ─────────────────────────────────────────────────────────────────
HOSTNAME=$(gum input --header "Hostname" --placeholder "nixos" --value "nixos")
HOSTNAME=${HOSTNAME:-nixos}

# ── Secret assets (provided at install time; ISO stays generic) ──────────────
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
extra_args=()
while IFS=$'\t' read -r name target mode; do
    [ -z "$name" ] && continue
    gum confirm "Provide asset '${name}' (→ ${target})?" || continue
    method=$(gum choose --header "How to provide ${name}?" "Read from a file" "Paste contents")
    dst="${STAGE}/${name}"
    if [ "$method" = "Read from a file" ]; then
        src=$(gum file --header "Select ${name}")
        cp "$src" "$dst"
    else
        gum write --header "Paste ${name} (Ctrl+D when done)" > "$dst"
    fi
    chmod "${mode:-0400}" "$dst"
    extra_args+=(--extra-files "$dst" "$target")
done < <(jq -r '.assets[]? | [.name, .target, (.mode // "0400")] | @tsv' "$MANIFEST")

# ── Confirm ──────────────────────────────────────────────────────────────────
gum style --border normal --padding "0 1" \
    "Disk:     ${DISK_DEVICE}" "Hostname: ${HOSTNAME}" "Style:    ${FLAKE_STYLE}"
gum confirm "Proceed with the install? This WIPES ${DISK_DEVICE}." || { echo "Aborted."; exit 1; }

# ── EFI vs legacy ────────────────────────────────────────────────────────────
efi_args=()
[ -d /sys/firmware/efi ] && efi_args+=(--write-efi-boot-entries)

# ── Seed: whole flake + flat identity overlay so reconcile applies it ────────
# Merge the chosen hostname into the primary module's FLAT settings file (the
# same flat file the local flake reads, e.g. router-settings.json), preserving
# any other committed values. Only closure-safe keys here.
SETTINGS=$(mktemp)
PRIMARY_PATH=$(jq -r '.primarySettingsPath // ""' "$MANIFEST")
EXISTING="${FLAKE_DIR}/${PRIMARY_PATH}"
if [ -n "$PRIMARY_PATH" ] && [ -f "$EXISTING" ]; then
    jq --arg h "$HOSTNAME" '.hostName = $h' "$EXISTING" > "$SETTINGS"
else
    jq -n --arg h "$HOSTNAME" '{ hostName: $h }' > "$SETTINGS"
fi

if [ "$FLAKE_STYLE" = "local" ]; then
    extra_args+=(--extra-files "${FLAKE_DIR}/" "etc/nixos")
    if [ -n "$PRIMARY_PATH" ]; then
        extra_args+=(--extra-files "$SETTINGS" "etc/nixos/${PRIMARY_PATH}")
    fi
fi

echo ":: Installing template offline…"
LOG=/tmp/install-helper.log
if disko-install \
    --flake "${FLAKE_DIR}#${HOST_ATTR}" \
    --disk "${DISK_NAME}" "${DISK_DEVICE}" \
    "${efi_args[@]}" \
    "${extra_args[@]}" \
    2>&1 | tee "$LOG"; then
    gum style --foreground 42 "Install complete — rebooting; identity is applied on first boot."
    sleep 5
    reboot
else
    echo "INSTALL FAILED — log: ${LOG}"
    sleep 3
    less "$LOG" || true
    exec bash -i
fi
