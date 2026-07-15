#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  lib-flash.sh — shared "write the built ISO to a USB drive" helper, sourced by
#  wizard.sh and install.sh. Interactive + destructive: it only ever touches the
#  device the technician picks and confirms, and writes via `sudo dd`.
#
#  Deps (present in the sourcing app's runtimeInputs): gum, jq, util-linux
#  (lsblk), plus host `sudo`/`dd`/`sync` on PATH.
# ════════════════════════════════════════════════════════════════════════════

# List candidate block devices as TSV "dev\tsize\tmodel\ttran".
#   _flash_list_devices removable   → USB / removable disks only (the safe set)
#   _flash_list_devices all         → every whole disk (dangerous fallback)
_flash_list_devices() {
    local scope="$1" filter
    if [ "$scope" = "removable" ]; then
        filter='select(.type=="disk") | select(.rm==true or .tran=="usb")'
    else
        filter='select(.type=="disk")'
    fi
    lsblk -dJ -o NAME,SIZE,MODEL,TRAN,RM,TYPE 2>/dev/null \
        | jq -r ".blockdevices[] | ${filter}
            | \"/dev/\(.name)\t\(.size)\t\(.model // \"?\")\t\(.tran // \"?\")\""
}

# Offer to flash "$1" (an .iso path) to a chosen USB device.
flash_iso() {
    local iso="$1"
    [ -n "$iso" ] && [ -f "$iso" ] || return 0

    gum confirm "Flash this ISO to a USB drive now?" --default=false </dev/tty || return 0

    local scope="removable"
    local -a devs=()
    mapfile -t devs < <(_flash_list_devices removable)
    if [ "${#devs[@]}" -eq 0 ]; then
        if gum confirm "No removable USB disk detected. List ALL disks (dangerous)?" \
            --default=false </dev/tty; then
            scope="all"
            mapfile -t devs < <(_flash_list_devices all)
        fi
    fi
    if [ "${#devs[@]}" -eq 0 ]; then
        echo "No target disks found — flash manually:" >&2
        echo "  sudo dd if=\"$iso\" of=/dev/sdX bs=4M status=progress conv=fsync" >&2
        return 0
    fi

    # Present human-readable rows; recover the device path from the selection.
    local line dev
    line=$(printf '%s\n' "${devs[@]}" \
        | awk -F'\t' '{printf "%s\t%s  %s  [%s]\n",$1,$2,$3,$4}' \
        | gum choose --header "Target USB device (scope: ${scope}):") || return 0
    dev=$(printf '%s' "$line" | cut -f1)
    [ -n "$dev" ] || return 0

    local size model
    size=$(printf '%s\n' "${devs[@]}" | awk -F'\t' -v d="$dev" '$1==d{print $2}')
    model=$(printf '%s\n' "${devs[@]}" | awk -F'\t' -v d="$dev" '$1==d{print $3}')

    gum style --border double --padding "1 2" --border-foreground 196 --foreground 196 \
        "ERASE ${dev}" "${size}  ${model}" "ALL DATA ON THIS DEVICE WILL BE LOST"
    gum confirm "Write $(basename "$iso") to ${dev}?" --default=false </dev/tty || {
        echo "Flash cancelled."; return 0
    }

    # Best-effort unmount of any mounted partitions on the target first.
    local part
    while IFS= read -r part; do
        [ -n "$part" ] && sudo umount "/dev/$part" 2>/dev/null || true
    done < <(lsblk -ln -o NAME "$dev" 2>/dev/null | tail -n +2)

    gum style --foreground 42 "Writing ${dev} — this can take a few minutes…"
    if sudo dd if="$iso" of="$dev" bs=4M status=progress conv=fsync && sudo sync; then
        gum style --foreground 42 "Done — ${dev} is ready to boot."
    else
        echo "Flash FAILED. You can retry manually:" >&2
        echo "  sudo dd if=\"$iso\" of=\"$dev\" bs=4M status=progress conv=fsync" >&2
        return 1
    fi
}
