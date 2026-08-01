#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  lib-preflight.sh — prove the offline closure is complete BEFORE wiping a disk.
#
#  Why this exists. The ISO does not hand disko-install a prebuilt system; it
#  hands it a flake, and disko-install RE-DERIVES the system on the target —
#  and not even the same one we baked. Its install-cli.nix installs
#
#    originalSystem.extendModules { modules = [{
#      boot.loader.efi.canTouchEfiVariables = mkVMOverride writeEfiBootEntries;
#      boot.loader.grub.devices             = mkVMOverride (attrValues diskMappings);
#    }]; }
#
#  where writeEfiBootEntries is decided by the firmware that booted the ISO and
#  diskMappings by the disk the technician picked. So the system that gets
#  installed is a function of the machine, and the closure was baked before the
#  machine was known.
#
#  When those two agree with what was baked, nothing is built and the install is
#  genuinely offline. When they disagree by even one store path, the consequences
#  are wildly out of proportion: `offline-closure.nix` ships RUNTIME closures —
#  outputs — and deliberately not the build-time closure, because that is gcc,
#  the bootstrap chain and every source tarball, several gigabytes. So rebuilding
#  one trivial `runCommand` sends nix looking for a stdenv it does not have,
#  which sends it to build bash, which sends it to fetch bison from gnu.org, and
#  the install dies three layers from anything resembling the cause — after the
#  disk has been wiped.
#
#  Hence: ask nix what it would build, before touching the disk, and refuse to
#  start if the answer is anything at all. A missing closure is a defect in the
#  IMAGE, and it should be reported as one on the console rather than discovered
#  as a failed download halfway through an install.
# ════════════════════════════════════════════════════════════════════════════

# preflight_offline <flake-dir> <attr> <disk-name> <disk-device> <efi-bool>
#   0 — nothing to build; the closure covers this machine.
#   1 — something would be built; the list has been printed.
# Skipped (0) when the manifest carries no install-cli.nix path, so an ISO built
# by an older framework still installs.
preflight_offline() {
    local flake_dir="$1" attr="$2" disk_name="$3" disk_device="$4" efi="$5"
    local cli to_build

    cli=$(jq -r '.diskoInstallCli // ""' "$MANIFEST" 2>/dev/null || echo "")
    if [ -z "$cli" ] || [ ! -e "$cli" ]; then
        return 0
    fi

    echo ":: checking the offline closure covers this machine…"
    # --dry-run reports what WOULD be realised without realising it. Everything
    # it names is a path this ISO should have carried and does not.
    to_build=$(nix-build "$cli" \
        --dry-run --impure --no-out-link \
        --argstr flake "$flake_dir" \
        --argstr flakeAttr "$attr" \
        --argstr rootMountPoint /mnt \
        --arg writeEfiBootEntries "$efi" \
        --arg diskMappings "{ ${disk_name} = \"${disk_device}\"; }" \
        --argstr extraSystemConfig '{}' \
        -A installToplevel -A closureInfo -A diskoScript 2>&1 |
        sed -n '/derivations will be built/,/^[^ ]/p' | grep -E '^\s+/nix/store/' || true)

    [ -z "$to_build" ] && return 0

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo " OFFLINE CLOSURE INCOMPLETE — refusing to touch ${disk_device}."
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    echo " This ISO does not carry everything the install needs. nix would"
    echo " have to BUILD the following, and there is no network here:"
    echo ""
    printf '%s\n' "$to_build" | sed 's|^\s*|   |'
    echo ""
    echo " Nothing has been written to the disk."
    echo ""
    echo " This is a defect in the IMAGE, not in this machine. It means the"
    echo " system disko-install would install here differs from the one that"
    echo " was baked — the two inputs that vary per machine are the firmware"
    echo " mode (UEFI vs BIOS, here: writeEfiBootEntries=${efi}) and the"
    echo " target disk (here: ${disk_device})."
    echo ""
    echo " Rebuild the ISO with a framework that bakes this combination, or"
    echo " install this machine over the network with"
    echo "   nix run <project>#deploy -- root@<ip>"
    echo ""
    return 1
}
