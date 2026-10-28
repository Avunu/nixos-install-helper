# bootstrap-host — create the repository for ONE machine, in the current directory.
#
# The body of the `bootstrap-host` program (lib/mk-host.nix wraps it with the
# environment below and its tools, and writeShellApplication adds the
# `set -euo pipefail` and runs shellcheck over it). The wizard offers it in a
# directory that is not a project yet; `nix run github:Owner/project#bootstrap`
# runs it directly.
#
# What it leaves behind is templates/host-repo with this machine's values filled
# in, plus what only this machine has:
#
#   <root>-settings.json      the installer questionnaire's answers (tracked)
#   secrets.nix               who can decrypt each secret
#   secrets/key.age           the machine's agenix identity, freshly generated,
#                             encrypted to the operators only — never to the machine
#   secrets/github-token.age  `access-tokens = github.com=<token>`, encrypted to
#                             the operators and the identity above (private repos)
#
# …committed, optionally pushed, and the flake's `repo` pointing at the GitHub
# repository it was pushed to. The wizard then continues with `nix run .` in
# the new repository.
#
# Environment (set by lib/mk-host.nix / mkProject's app wrapper):
#   IH_HOST_TEMPLATE  the directory to copy (templates/host-repo, project values
#                     already substituted)
#   IH_HOST_ROOT      the project's option root: names the settings file
#   IH_UPSTREAM       the flake ref the new repository takes the project from
#   IH_ADMIN_KEYS     JSON list of SSH public keys that can decrypt every
#                     machine's secrets, beside the machine's own sshKeys
#   IH_DEFAULT_OWNER  the GitHub owner suggested for the repository
#   IH_HOST_TOPIC     the topic a published repository is given
#   IH_SCRIPTS        this framework's scripts (lib-repo.sh, configure.sh)
# Optional, to skip a prompt: IH_REPO_OWNER, IH_REPO_NAME, IH_GITHUB_TOKEN,
# IH_REPO_PUBLIC=1. IH_NONINTERACTIVE=1 takes every default instead of asking.

# shellcheck source=/dev/null
source "${IH_SCRIPTS}/lib-repo.sh"

SETTINGS_FILE="${IH_HOST_ROOT}-settings.json"
SETTINGS_SRC="installer/${SETTINGS_FILE}"
NONINTERACTIVE="${IH_NONINTERACTIVE:-}"

die() {
    gum style --foreground 196 "$@" >&2
    exit 1
}

# ask <header> <default> — a text prompt, or the default when nobody is there.
ask() {
    if [ -n "$NONINTERACTIVE" ]; then
        printf '%s' "$2"
    else
        gum input --header "$1" --value "$2"
    fi
}

gum style --border double --padding "1 2" --border-foreground 212 \
    "New host repository" "One repository per machine; the machine tracks it."

# ── 0. Is this directory ours to fill? ───────────────────────────────────────
# The settings the wizard just collected (installer/), a previous build's
# result link and an existing .git are expected. Anything else is somebody's
# work, and copying a flake over it is not something to do quietly.
[ -f flake.nix ] && die "$(pwd) already has a flake.nix — it is a project already."
stray=$(find . -mindepth 1 -maxdepth 1 ! -name installer ! -name result ! -name .git ! -name .direnv -print -quit)
[ -n "$stray" ] && die "$(pwd) is not empty (found ${stray#./}). Run this in a new, empty directory."

# ── 1. Settings ──────────────────────────────────────────────────────────────
if [ ! -f "$SETTINGS_SRC" ]; then
    IH_CONFIGURE_NO_NEXT=1 bash "${IH_SCRIPTS}/configure.sh" installer/settings.json
fi
[ -f "$SETTINGS_SRC" ] || die "No ${SETTINGS_SRC}: the questionnaire wrote nothing."
jq -e 'type == "object"' "$SETTINGS_SRC" >/dev/null || die "${SETTINGS_SRC} is not a JSON object."
HOST=$(jq -r '.hostName // .hostname // "nixos"' "$SETTINGS_SRC")

# ── 2. Name and place ────────────────────────────────────────────────────────
gh_login=$(gh api user -q .login 2>/dev/null || true)
OWNER="${IH_REPO_OWNER:-$(ask "GitHub owner (user or organization)" "${IH_DEFAULT_OWNER:-$gh_login}")}"
REPO="${IH_REPO_NAME:-$(ask "Repository name (${OWNER:-owner}/…)" "$(basename "$PWD")")}"
[[ "$OWNER" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die "'${OWNER}' is not a valid GitHub owner."
[[ "$REPO" =~ ^[A-Za-z0-9._-]+$ ]] || die "'${REPO}' is not a valid repository name."

if [ -n "$NONINTERACTIVE" ] || [ "${IH_REPO_PUBLIC:-0}" = "1" ]; then
    PRIVATE=$([ "${IH_REPO_PUBLIC:-0}" = "1" ] && echo no || echo yes)
elif gum confirm "Private repository?" --default=true; then
    PRIVATE=yes
else
    PRIVATE=no
fi
[ "$PRIVATE" = "no" ] && export IH_REPO_PUBLIC=1

# ── 3. Who can decrypt ───────────────────────────────────────────────────────
# age encrypts to ssh-ed25519 and ssh-rsa public keys. The operators are the
# keys already trusted in the settings (sshKeys) and the project's standing
# admins (lib.mkHost adminKeys), so every repository it
# creates stays decryptable by the same people; but secrets nobody present can
# decrypt are worse than none, so at least one recipient must be a key whose
# private half is on this machine.
local_keys=()
for pub in "$HOME"/.ssh/id_*.pub; do
    [ -r "$pub" ] && [ -r "${pub%.pub}" ] || continue
    # `|| true`: read exits 1 on a last line with no newline, which ssh-keygen
    # does not always write, even though it filled the variables.
    read -r ktype kbody _ <"$pub" || true
    case "$ktype" in ssh-ed25519 | ssh-rsa) local_keys+=("$ktype $kbody") ;; esac
done
mapfile -t admins < <(
    {
        jq -r '.sshKeys[]?' "$SETTINGS_SRC"
        jq -r '.[]' "${IH_ADMIN_KEYS:-/dev/null}" 2>/dev/null || true
    } | awk '($1 == "ssh-ed25519" || $1 == "ssh-rsa") && !seen[$1 " " $2]++ { print $1 " " $2 }'
)

usable=no
for a in "${admins[@]}"; do
    for l in "${local_keys[@]}"; do [ "$a" = "$l" ] && usable=yes; done
done
if [ "$usable" = "no" ]; then
    [ "${#local_keys[@]}" -gt 0 ] || die "No SSH key to encrypt to: none in the settings' sshKeys has a private half here," \
        "and ~/.ssh has no id_*.pub with its private key. Create one (ssh-keygen -t ed25519) and re-run."
    if [ "${#local_keys[@]}" -eq 1 ] || [ -n "$NONINTERACTIVE" ]; then
        admins+=("${local_keys[0]}")
    else
        admins+=("$(printf '%s\n' "${local_keys[@]}" | gum choose --header "None of the SSH keys in the settings is on this machine. Encrypt the host's secrets to:")")
    fi
fi
recipients=()
for a in "${admins[@]}"; do recipients+=(-r "$a"); done

# ── 4. The host's agenix identity ────────────────────────────────────────────
# Generated here so its public half can be a recipient of the other secrets
# before the machine exists. The private half is stored only encrypted to the
# operators: every install path decrypts it (the devShell, or the wizard with
# your SSH key) and writes it to /etc/agenix/key.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
age-keygen -o "${WORK}/key" 2>/dev/null
AGE_PUB=$(age-keygen -y "${WORK}/key")

mkdir -p secrets
age -a "${recipients[@]}" -o secrets/key.age "${WORK}/key"

# ── 5. Read-only token (private repositories) ────────────────────────────────
# The machine fetches its own configuration from GitHub; a private repository
# needs a credential, and it must reach nix.conf as an `access-tokens` line.
# Encrypted to the host's identity too, so it decrypts on first activation.
haveToken=no
if [ "$PRIVATE" = "yes" ]; then
    TOKEN="${IH_GITHUB_TOKEN:-}"
    if [ -z "$TOKEN" ] && [ -z "$NONINTERACTIVE" ]; then
        gum style --faint \
            "The machine needs a read-only token to fetch ${OWNER}/${REPO} (it is private)." \
            "A fine-grained personal access token: resource owner ${OWNER}, repository" \
            "access ${OWNER}/${REPO} (add it once it exists), permissions Contents → Read-only." \
            "Leave empty to skip; the machine cannot upgrade itself until a token is added."
        TOKEN=$(gum input --password --header "Read-only GitHub token (optional)")
    fi
    if [ -n "$TOKEN" ]; then
        [[ "$TOKEN" =~ ^[A-Za-z0-9_]+$ ]] || die "That does not look like a GitHub token."
        printf 'access-tokens = github.com=%s\n' "$TOKEN" |
            age -a "${recipients[@]}" -r "$AGE_PUB" -o secrets/github-token.age
        haveToken=yes
    fi
    unset TOKEN
fi

# ── 6. Write the repository ──────────────────────────────────────────────────
cp -r --no-preserve=mode,ownership "${IH_HOST_TEMPLATE}/." .
find . -path ./.git -prune -o -type f -print0 | xargs -0 sed -i \
    -e "s|@HOST@|${HOST}|g" \
    -e "s|@OWNER@|${OWNER}|g" \
    -e "s|@REPO@|${REPO}|g" \
    -e "s|@UPSTREAM@|${IH_UPSTREAM}|g"
nixfmt flake.nix

# The settings are tracked from here on: the machine's Nix reads them, so they
# no longer belong in the untracked installer/ directory.
mv "$SETTINGS_SRC" "$SETTINGS_FILE"
rmdir installer 2>/dev/null || true

{
    echo "# Who can decrypt each secret. Re-encrypt after editing: agenix -r"
    echo "let"
    echo "  admins = ["
    for a in "${admins[@]}"; do printf '    "%s"\n' "$a"; done
    echo "  ];"
    echo "  # The host's identity (/etc/agenix/key, from secrets/key.age)."
    printf '  host = "%s";\n' "$AGE_PUB"
    echo "in"
    echo "{"
    echo "  # Admins only: the installer decrypts it to hand the machine its identity."
    echo "  \"secrets/key.age\".publicKeys = admins;"
    echo "  \"secrets/github-token.age\".publicKeys = admins ++ [ host ];"
    echo "}"
} >secrets.nix

# ── 7. Lock, commit, push ────────────────────────────────────────────────────
repo_init_commit "$PWD" "init: ${HOST}"
pushed=no
repo_publish "$PWD" "${OWNER}/${REPO}" "${IH_HOST_TOPIC:-}" && pushed=yes

gum style --foreground 42 "Created ${PWD}" \
    "Machine tracks: github:${OWNER}/${REPO}#default"
if [ "$pushed" = "no" ]; then
    gum style --foreground 214 \
        "Not on GitHub yet: an installed machine cannot upgrade itself until ${OWNER}/${REPO} exists and is pushed."
fi
if [ "$PRIVATE" = "yes" ] && [ "$haveToken" = "no" ]; then
    gum style --foreground 214 \
        "No token stored: write one to secrets/github-token.age (agenix -e) before the machine can fetch its private repository."
fi
