#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  lib-build.sh — build an installer ISO and offer to flash it. Sourced by
#  wizard.sh and install.sh, which used to carry two copies of this (and had
#  drifted: only the wizard refused to build without a required asset).
#
#  Expects the sourcing script to have sourced lib-flash.sh (flash_iso) and set
#  FLAKE (lib-flake.sh's resolve_flake). Needs gum, jq and nix on PATH.
#
#  This is the same whether the flake is a project checkout, a freshly
#  bootstrapped repository, or the generic template an empty directory falls
#  back to: nothing here asks which.
# ════════════════════════════════════════════════════════════════════════════

# The last step of every ISO build is one mksquashfs pass over the whole offline
# closure, and mksquashfs suppresses its progress bar whenever stdout is not a
# tty — which under `nix build` it never is. So the build goes completely silent
# after "Creating 4.0 filesystem on nix-store.squashfs" for as long as that pass
# takes (minutes, on a multi-GB closure), and looks hung. Say so up front.
squashfs_note() {
    gum style --faint \
        "The build ends with a single mksquashfs pass over the whole offline closure." \
        "mksquashfs prints nothing to a non-tty, so the log stops at \"Creating 4.0" \
        "filesystem on nix-store.squashfs\" and stays there for several minutes." \
        "That is the compression running, not a hang — watch CPU if in doubt."
}

# Work out which nix flags the UNATTENDED build needs, into the global array
# `impure`. Two things force --impure (both are builtins.getEnv in the eval):
#   • untracked per-root settings files — a flake only copies git-TRACKED files
#     into `self`, so installer/<root>-settings.json is injected by path
#     (IH_SETTINGS_DIR);
#   • env-sourced secret assets.
# Then refuse outright if a required asset has no value: an unattended ISO
# cannot ask on the box, so it would install a machine without it.
prepare_unattended_build() {
    impure=()
    if ls installer/*-settings.json >/dev/null 2>&1; then
        impure=(--impure)
        IH_SETTINGS_DIR="$(realpath installer)"
        export IH_SETTINGS_DIR
        echo ":: seeding installer/ settings into the build (--impure)"
    fi
    if jq -e 'any(.[]; .source.env != null)' "${IH_ASSETS:-/dev/null}" >/dev/null 2>&1; then
        impure=(--impure)
        echo ":: env-sourced secrets detected — building --impure"
    fi

    local missing=() name env
    while IFS=$'\t' read -r name env; do
        [ -z "$name" ] && continue
        [ -n "${!env:-}" ] || missing+=("${name} (\$${env})")
    done < <(jq -r '.[]? | select(.required == true and .source.env != null and .source.file == null) | [.name, .source.env] | @tsv' "${IH_ASSETS:-/dev/null}" 2>/dev/null || true)
    if [ "${#missing[@]}" -gt 0 ]; then
        gum style --foreground 196 "Required asset(s) not set: ${missing[*]}" \
            "Enter the project's devShell (direnv) so they are exported, then re-run."
        return 1
    fi
}

# Build `<FLAKE>#<attr>` in the foreground with live logs — a `gum spin` wrapper
# would hide the build output, so an evaluation/assertion failure would look like
# a silent exit ("no error, no ISO") instead of showing the actual cause.
# Uses the global `impure` array (empty unless prepare_unattended_build set it).
build_iso() {
    local attr="$1"
    gum style --foreground 212 "Building ${attr}… (build logs below)"
    squashfs_note
    if ! nix build "${impure[@]}" "${FLAKE}#${attr}" --print-build-logs; then
        gum style --foreground 196 "Build of ${attr} FAILED — see the log above for the cause."
        return 1
    fi
}

# Point at the ISO the last build left in ./result and offer to flash it.
show_iso() {
    local iso
    iso=$(find -L result/iso -name '*.iso' 2>/dev/null | head -1)
    if [ -n "$iso" ]; then
        gum style --foreground 42 "ISO: $iso"
        flash_iso "$iso"
        echo "  Flash manually:  sudo dd if=\"$iso\" of=/dev/sdX bs=4M status=progress conv=fsync"
        echo "  Or boot it directly in a VM to test the install."
    else
        echo "Build finished but no ISO was found under ./result/iso" >&2
    fi
}
