#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  lib-flake.sh — pick the flake the apps build. Sourced by wizard.sh, install.sh
#  and deploy.sh.
#
#  Order of precedence:
#    1. IH_FLAKE_REF, when set explicitly.
#    2. "." — the working tree, when it is a project (has a flake.nix). This is
#       the `nix run .#` case: edits in the checkout are what gets built.
#    3. IH_FLAKE_DEFAULT — the flake that shipped this app, exported by mkApp as
#       its store path. This is the `nix run github:Owner/repo` case from a
#       directory that is not a project yet: the bootstrap wizard writes its
#       settings into the cwd and builds the template it came from.
# ════════════════════════════════════════════════════════════════════════════

resolve_flake() {
    if [ -n "${IH_FLAKE_REF:-}" ]; then
        printf '%s\n' "$IH_FLAKE_REF"
    elif [ -f flake.nix ]; then
        printf '%s\n' "."
    else
        printf '%s\n' "${IH_FLAKE_DEFAULT:-.}"
    fi
}
