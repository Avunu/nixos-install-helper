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

# ── Seed: synthesized local flake + chosen identity so first boot applies it ──
# The synthesized /etc/nixos/flake.nix reads ./settings.json; write the chosen
# hostName nested under the project's primary option root (only closure-safe keys).
SETTINGS=$(mktemp)
PRIMARY_ROOT=$(jq -r '.primaryRoot // ""' "$MANIFEST")
if [ -n "$PRIMARY_ROOT" ]; then
    jq -n --arg r "$PRIMARY_ROOT" --arg h "$HOSTNAME" '{ ($r): { hostName: $h } }' > "$SETTINGS"
else
    jq -n --arg h "$HOSTNAME" '{ hostName: $h }' > "$SETTINGS"
fi

if [ "$FLAKE_STYLE" = "local" ] && [ -f /etc/installer-local-flake/flake.nix ]; then
    # /etc/installer-local-flake/flake.nix is an environment.etc symlink into
    # /etc/static; disko-install's `cp -a` would copy it as a dangling symlink, so
    # dereference to a real file first. ($SETTINGS/$MARKER are already real files.)
    FLAKE_REAL=$(mktemp)
    cp -L /etc/installer-local-flake/flake.nix "$FLAKE_REAL"
    extra_args+=(--extra-files "$FLAKE_REAL" "etc/nixos/flake.nix")
    extra_args+=(--extra-files "$SETTINGS" "etc/nixos/settings.json")
    # The guided template boots with a generic identity; drop a marker so the
    # first-boot reconcile rebuilds /etc/nixos#default and applies the chosen host.
    MARKER=$(mktemp)
    extra_args+=(--extra-files "$MARKER" "etc/nixos/.first-boot-reconcile")
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
