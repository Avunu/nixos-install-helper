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

# preflight_offline <flake-dir> <attr> <disk-name> <disk-device> <efi-bool> <root-mount-point>
#   0 — the install evaluates and realises offline on this machine.
#   1 — it does not; the reason has been printed.
# Skipped (0) when the manifest carries no install-cli.nix path, so an ISO built
# by an older framework still installs.
preflight_offline() {
    local flake_dir="$1" attr="$2" disk_name="$3" disk_device="$4" efi="$5"
    # disko-install bakes rootMountPoint INTO diskoScript, so checking a
    # different one from the one the install will use checks a different script.
    local root_mount_point="${6:-/mnt}"
    local cli flake_path out rc to_build

    cli=$(jq -r '.diskoInstallCli // ""' "$MANIFEST" 2>/dev/null || echo "")
    if [ -z "$cli" ] || [ ! -e "$cli" ]; then
        return 0
    fi

    echo ":: checking the offline closure covers this machine…"

    # Resolve the flake to a store path first, because that is what
    # disko-install evaluates (`nix flake metadata --json | .path`) and it is not
    # the same thing as the directory argument. /etc/installer-flake is an
    # environment.etc SYMLINK into /etc/static; hand THAT to builtins.getFlake
    # and nix copies the link itself into the store, then fails to find a
    # flake.nix inside a symlink. Checking it would check something the install
    # never evaluates.
    # stderr stays OUT of the pipe: nix prints "you don't have Internet access;
    # disabling some network-dependent features" on exactly the machine this
    # runs on, and folding that into the JSON makes jq fail and this fall back
    # to the symlink it exists to avoid.
    flake_path=$(nix flake metadata --json \
        --extra-experimental-features 'nix-command flakes' \
        "$flake_dir" 2>/dev/null | jq -r '.path // empty' || true)
    [ -n "$flake_path" ] || flake_path="$flake_dir"

    # ── Why this REALISES rather than just asking ──────────────────────────────
    # "Would nix build anything?" is the wrong question, because for a guided ISO
    # the answer is permanently yes: disko writes the target device INTO
    # diskoScript, and the device is the question a guided ISO exists to ask, so
    # that one script cannot have been baked. The question that matters is
    # whether what must be built CAN be built here, with no network — which is
    # answered by building it.
    #
    # This costs nothing extra: disko-install runs exactly this nix-build as its
    # first step, before the disk is touched. Running it here only means a
    # failure is reported as what it is — an incomplete image — instead of as a
    # wall of nix output about a bison tarball.
    set +e
    out=$(nix-build "$cli" \
        --impure --no-out-link \
        --argstr flake "$flake_path" \
        --argstr flakeAttr "$attr" \
        --argstr rootMountPoint "$root_mount_point" \
        --arg writeEfiBootEntries "$efi" \
        --arg diskMappings "{ ${disk_name} = \"${disk_device}\"; }" \
        --argstr extraSystemConfig '{}' \
        -A installToplevel -A closureInfo -A diskoScript 2>&1)
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        # Report what had to be built, so a guided ISO's one expected script is
        # visible and an unexpected twentieth is too.
        to_build=$(printf '%s\n' "$out" | awk '
            /derivations? will be built:/ { inblock = 1; next }
            /^[^[:space:]]/               { inblock = 0 }
            inblock && /\/nix\/store\//   { sub(/^[[:space:]]+/, ""); print }
        ')
        if [ -n "$to_build" ]; then
            echo ":: built here (the ISO could not have baked these):"
            printf '%s\n' "$to_build" | sed 's|^|   |'
        fi
        return 0
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo " OFFLINE CLOSURE INCOMPLETE — refusing to touch ${disk_device}."
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    echo " This ISO does not carry everything the install needs, and there"
    echo " is no network here. nix said:"
    echo ""
    printf '%s\n' "$out" | sed 's|^|   |'
    echo ""
    echo " Nothing has been written to the disk."
    echo ""
    echo " This is a defect in the IMAGE, not in this machine. It means the"
    echo " system disko-install would install here differs from the one that"
    echo " was baked — the inputs that vary per machine are the firmware"
    echo " mode (UEFI vs BIOS, here: writeEfiBootEntries=${efi}) and the"
    echo " target disk (here: ${disk_device})."
    echo ""
    echo " Rebuild the ISO with a framework that bakes this combination, or"
    echo " install this machine over the network with"
    echo "   nix run <project>#deploy -- root@<ip>"
    echo ""
    return 1
}
