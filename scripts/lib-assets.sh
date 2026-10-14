#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  lib-assets.sh — fill env-sourced assets from age files kept in the project.
#  Sourced by wizard.sh, install.sh and deploy.sh.
#
#  An asset may name both `source.env` and `source.ageFile` (a path relative to
#  the project root). When the env var is empty and the file is there, decrypt
#  it with the operator's SSH key and export the result, so everything
#  downstream (the impure ISO build reading getEnv, deploy.sh staging) sees an
#  ordinary env-sourced asset. A host repo keeps its machine's SSH host key this
#  way: encrypted to the admins, decrypted only at install time.
#
#  Identities: IH_AGE_IDENTITY (colon-separated paths) when set, otherwise every
#  ~/.ssh/id_* private key with an ed25519 or RSA .pub beside it. age reads the
#  .pub to skip non-matching keys, so a passphrase is only asked for the key the
#  file was actually encrypted to.
# ════════════════════════════════════════════════════════════════════════════

age_identities() {
    local ids=() f
    if [ -n "${IH_AGE_IDENTITY:-}" ]; then
        local IFS=:
        for f in $IH_AGE_IDENTITY; do
            [ -r "$f" ] && ids+=(-i "$f")
        done
    else
        for f in "$HOME"/.ssh/id_*; do
            case "$f" in *.pub) continue ;; esac
            [ -r "$f" ] && [ -r "$f.pub" ] || continue
            grep -qE '^(ssh-ed25519|ssh-rsa) ' "$f.pub" && ids+=(-i "$f")
        done
    fi
    printf '%s\n' "${ids[@]}"
}

load_age_assets() {
    local name env file value
    local ids=()
    while IFS=$'\t' read -r name env file; do
        [ -z "$name" ] && continue
        [ -n "${!env:-}" ] && continue
        [ -f "$file" ] || continue
        if [ "${#ids[@]}" -eq 0 ]; then
            mapfile -t ids < <(age_identities)
        fi
        if [ "${#ids[@]}" -eq 0 ]; then
            echo "!! ${file}: no SSH identity to decrypt it with (set IH_AGE_IDENTITY)" >&2
            return 0
        fi
        if value=$(age -d "${ids[@]}" "$file"); then
            export "${env}=${value}"
            echo ":: asset ${name}: decrypted ${file} into \$${env}"
        else
            echo "!! asset ${name}: could not decrypt ${file} with ${ids[*]}" >&2
        fi
    done < <(jq -r '.[]? | select(.source.env != null and .source.ageFile != null) | [.name, .source.env, .source.ageFile] | @tsv' "${IH_ASSETS:-/dev/null}" 2>/dev/null || true)
}
