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
#
#  There is no fourth choice. Falling back to "." with no flake.nix in it sends
#  nix searching upward from the cwd for one, and the error it ends on ("could
#  not find a flake.nix file") names neither this script nor what was missing.
# ════════════════════════════════════════════════════════════════════════════

# True when the working directory is itself a flake.
flake_in_cwd() { [ -f flake.nix ]; }

resolve_flake() {
    if [ -n "${IH_FLAKE_REF:-}" ]; then
        printf '%s\n' "$IH_FLAKE_REF"
    elif flake_in_cwd; then
        printf '%s\n' "."
    elif [ -n "${IH_FLAKE_DEFAULT:-}" ]; then
        # Explicit `path:`, not the bare store path: nix guesses the fetcher for a
        # bare path, and takes it for a git checkout (then refuses it as "not
        # owned by current user") whenever the source happens to hold a .git.
        case "$IH_FLAKE_DEFAULT" in
            /*) printf 'path:%s\n' "$IH_FLAKE_DEFAULT" ;;
            *) printf '%s\n' "$IH_FLAKE_DEFAULT" ;;
        esac
    else
        echo "!! $(pwd) has no flake.nix, and this app was not built with a default flake." >&2
        echo "   Run it from a project directory, or set IH_FLAKE_REF." >&2
        return 1
    fi
}
