#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  lib-repo.sh — turn a directory of files into a committed (and, if wanted,
#  published) flake repository. Sourced by new-host.sh, and available to a
#  project's own bootstrap program as "$IH_SCRIPTS/lib-repo.sh".
#
#  Needs git, nix, gum and, for repo_publish, gh on PATH.
# ════════════════════════════════════════════════════════════════════════════

# repo_init_commit <dir> <message>
# git init (if needed), stage everything, lock the flake, commit. The order is
# the point: a flake in a git repository sees only TRACKED files, so `nix flake
# lock` run before `git add` would evaluate a repository with nothing in it.
repo_init_commit() {
    local dir="$1" msg="$2"
    [ -d "$dir/.git" ] || git -C "$dir" init -q -b main
    git -C "$dir" add -A
    echo ":: locking flake inputs"
    nix flake lock "$dir"
    git -C "$dir" add flake.lock
    git -C "$dir" commit -q -m "$msg"
}

# repo_publish <dir> <owner/name> [topic]
# Offer to create the private GitHub repository and push. Returns 0 when pushed,
# 1 when it was declined or could not be done — never fatal, because the commit
# already exists and the push can be done later by hand. IH_NONINTERACTIVE
# always declines: publishing creates something on someone's GitHub account,
# which nothing unattended should do on its own.
repo_publish() {
    local dir="$1" slug="$2" topic="${3:-}" visibility="--private"
    [ "${IH_REPO_PUBLIC:-0}" = "1" ] && visibility="--public"
    if [ -n "${IH_NONINTERACTIVE:-}" ]; then
        echo "Not pushed (non-interactive). Later:  cd ${dir} && gh repo create ${slug} ${visibility} --source . --push"
        return 1
    fi
    if ! gum confirm "Create ${visibility#--} repo ${slug} on GitHub and push?"; then
        echo "Not pushed. Later:  cd ${dir} && gh repo create ${slug} ${visibility} --source . --push"
        return 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        echo "!! gh is not logged in — run \`gh auth login\`, then:" >&2
        echo "   cd ${dir} && gh repo create ${slug} ${visibility} --source . --push" >&2
        return 1
    fi
    if ! (cd "$dir" && gh repo create "$slug" "$visibility" --source . --push); then
        echo "!! gh repo create failed; the repository is committed locally in ${dir}." >&2
        return 1
    fi
    [ -n "$topic" ] && gh repo edit "$slug" --add-topic "$topic"
    return 0
}
