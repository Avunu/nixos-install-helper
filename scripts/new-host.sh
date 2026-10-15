#!/usr/bin/env bash
set -euo pipefail
# ════════════════════════════════════════════════════════════════════════════
#  new-host.sh — create the repository for ONE machine and push it, private.
#  Usage:  nix run github:Owner/project#new-host [-- <name>]
#
#  The new repo is the hostRepoTemplate (a flake that calls mkProject on itself
#  with flakeStyle = "repo") plus what only this machine has:
#    <root>-settings.json        the installer questionnaire's answers
#    secrets.nix                 admins + this machine's SSH host key
#    secrets/ssh-host-key.age    the machine's identity, encrypted to the admins
#    secrets/github-token.age    the bare read-only token, encrypted to the
#                                admins and the machine
#
#  Env (set by the mkProject app wrapper): IH_HOST_TEMPLATE, IH_HOST_OWNER,
#  IH_HOST_PREFIX, IH_HOST_TOPIC, IH_ADMIN_KEYS (JSON list), IH_ROOTS,
#  IH_PRIMARY_ROOT, plus configure.sh's IH_SCHEMA / IH_HINTS / IH_HAS_SETTINGS.
#  IH_GITHUB_TOKEN skips the token prompt.
# ════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

gum style --border double --padding "1 2" --border-foreground 212 \
    "New host repository" "One private repo per machine; the machine tracks it."

mapfile -t ADMINS < <(jq -r '.[]' "$IH_ADMIN_KEYS")
if [ "${#ADMINS[@]}" -eq 0 ]; then
    echo "hostRepo.adminKeys is empty: nobody could decrypt this host's secrets." >&2
    exit 1
fi

# ── 1. Settings ──────────────────────────────────────────────────────────────
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
IH_CONFIGURE_NO_NEXT=1 bash "${SCRIPT_DIR}/configure.sh" "${WORK}/settings/settings.json"
HOSTNAME_GUESS=$(jq -r '.hostName // .hostname // empty' "${WORK}/settings/${IH_PRIMARY_ROOT}-settings.json" 2>/dev/null || true)

# ── 2. Name and place ────────────────────────────────────────────────────────
NAME="${1:-}"
if [ -z "$NAME" ]; then
    NAME=$(gum input --header "Repository name (${IH_HOST_OWNER}/…)" \
        --value "${IH_HOST_PREFIX}${HOSTNAME_GUESS}")
fi
[ -z "$NAME" ] && { echo "No name given."; exit 1; }
REPO="github:${IH_HOST_OWNER}/${NAME}"
DIR="$(pwd)/${NAME}"
if [ -e "$DIR" ]; then
    echo "${DIR} already exists; not touching it." >&2
    exit 1
fi

cp -r "$IH_HOST_TEMPLATE" "$DIR"
chmod -R u+w "$DIR"
cp "${WORK}"/settings/*-settings.json "$DIR"/
sed -i \
    -e "s|@IH_REPO@|${REPO}|g" \
    -e "s|@IH_NAME@|${NAME}|g" \
    -e "s|@IH_HOST@|${HOSTNAME_GUESS:-${NAME}}|g" \
    "$DIR/flake.nix" "$DIR/README.md"

# ── 3. The machine's identity ────────────────────────────────────────────────
# Generated here rather than on first boot so its public half can be a
# recipient BEFORE the machine exists, and the token is decryptable the moment
# the installed system first activates.
ssh-keygen -q -t ed25519 -N "" -C "root@${HOSTNAME_GUESS:-${NAME}}" -f "${WORK}/host_key"
HOST_PUB=$(cut -d' ' -f1,2 "${WORK}/host_key.pub")

{
    echo "# Who can decrypt each secret. Re-encrypt after editing: ragenix -r"
    echo "let"
    echo "  admins = ["
    for k in "${ADMINS[@]}"; do printf '    "%s"\n' "$k"; done
    echo "  ];"
    echo "  # /etc/ssh/ssh_host_ed25519_key on the machine (secrets/ssh-host-key.age)."
    printf '  host = "%s";\n' "$HOST_PUB"
    echo "in"
    echo "{"
    echo "  \"secrets/github-token.age\".publicKeys = admins ++ [ host ];"
    echo "  # Admins only: the installer decrypts it to hand the machine its identity."
    echo "  \"secrets/ssh-host-key.age\".publicKeys = admins;"
    echo "}"
} > "$DIR/secrets.nix"

recipients=()
for k in "${ADMINS[@]}"; do recipients+=(-r "$k"); done

mkdir -p "$DIR/secrets"
age "${recipients[@]}" -o "$DIR/secrets/ssh-host-key.age" < "${WORK}/host_key"

# ── 4. The read-only token ───────────────────────────────────────────────────
TOKEN="${IH_GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ]; then
    gum style --faint \
        "A fine-grained personal access token, resource owner ${IH_HOST_OWNER}," \
        "repository access: the host repos (and any private flake inputs)," \
        "permissions: Contents → Read-only. Nothing else."
    TOKEN=$(gum input --password --header "Read-only GitHub token")
fi
[ -z "$TOKEN" ] && { echo "No token given." >&2; exit 1; }
printf '%s\n' "$TOKEN" \
    | age "${recipients[@]}" -r "$HOST_PUB" -o "$DIR/secrets/github-token.age"
unset TOKEN

# ── 5. Lock, commit, push ────────────────────────────────────────────────────
git -C "$DIR" init -q -b main
git -C "$DIR" add -A
echo ":: locking flake inputs"
nix flake lock "$DIR"
git -C "$DIR" add flake.lock
git -C "$DIR" commit -q -m "init: ${NAME}"

if gum confirm "Create private repo ${IH_HOST_OWNER}/${NAME} on GitHub and push?"; then
    (cd "$DIR" && gh repo create "${IH_HOST_OWNER}/${NAME}" --private --source . --push)
    [ -n "${IH_HOST_TOPIC:-}" ] && gh repo edit "${IH_HOST_OWNER}/${NAME}" --add-topic "$IH_HOST_TOPIC"
else
    echo "Not pushed. Later:  cd ${NAME} && gh repo create ${IH_HOST_OWNER}/${NAME} --private --source . --push"
fi

gum style --foreground 42 "Created ${DIR}" \
    "Install it:  cd ${NAME} && nix run" \
    "The token must be able to read ${IH_HOST_OWNER}/${NAME}: if it lists" \
    "selected repositories, add this one to it."
