# @IH_NAME@

NixOS configuration for **@IH_HOST@**. The machine tracks this repository
(`@IH_REPO@`): push to the default branch and its next daily upgrade switches to
it. Nothing on the machine itself needs editing; `/etc/nixos` is not used.

| File | What it holds |
|------|---------------|
| `*-settings.json` | the values the installer asked about (host name, user, disk, …) |
| `local.nix` | anything else: extra packages, per-machine NixOS config |
| `secrets.nix` | who can decrypt each file in `secrets/` |
| `secrets/github-token.age` | the read-only GitHub token (just the `github_pat_…` value), so the machine can fetch this private repo |
| `secrets/ssh-host-key.age` | the machine's SSH host key, encrypted to the admins only; the installer decrypts it and gives it to the machine, which then uses it to decrypt its own secrets |

## Install or reinstall

```sh
nix run          # wizard: network install (nixos-anywhere) or an unattended ISO
```

The installer decrypts `secrets/ssh-host-key.age` with your SSH key (any
`~/.ssh/id_*` with a matching `.pub`, or the paths in `IH_AGE_IDENTITY`,
colon-separated).

## Secrets

```sh
nix develop
ragenix -e secrets/<name>.age            # edit
ragenix -r                               # re-encrypt after changing secrets.nix
```

New secrets are declared in `secrets.nix` and, for the machine, as
`age.secrets.<name>.file = ./secrets/<name>.age;` in `local.nix`.

### Rotating the GitHub token

The token is a fine-grained PAT with **Contents: read-only** on the host repos
(and any private flake inputs). Before it expires:

```sh
nix develop
ragenix -e secrets/github-token.age   # just the new token, nothing else
```

Push, and wait for the machine to pick it up (it fetches with the old token and
activates the new one) before revoking the old one.
