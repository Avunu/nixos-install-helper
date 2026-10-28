# @REPO@

NixOS configuration for **@HOST@**. The machine tracks this repository
(`github:@OWNER@/@REPO@`): push to the default branch and its next upgrade
switches to it. `/etc/nixos` is not used.

| File | What it holds |
|------|---------------|
| `@ROOT@-settings.json` | the values the installer asked about (host name, user, disk, SSH keys, features) |
| `host.nix` | anything else: extra packages, per-machine NixOS config |
| `flake.lock` | the exact version of every input; update it here, never on the machine |
| `secrets.nix` | who can decrypt each file in `secrets/` |
| `secrets/key.age` | the machine's agenix identity, encrypted to the operators only |
| `secrets/github-token.age` | the read-only GitHub token the machine fetches this repository with (private repos) |

Flake input updates arrive as dependabot pull requests, merged once the
configuration still evaluates (`.github/workflows/eval.yml`).

## Install or reinstall

```sh
nix run          # network install (nixos-anywhere) or an offline ISO
```

The installer decrypts `secrets/key.age` with your SSH key (any `~/.ssh/id_*`
with a matching `.pub`, or the paths in `IH_AGE_IDENTITY`, colon-separated) and
writes it to `/etc/agenix/key` on the machine. Because the key lives in this
repository and not on the machine, a reinstall onto a new disk decrypts the
same secrets without re-keying anything.

## Secrets

```sh
nix develop
agenix -e secrets/<name>.age     # create or edit (identity: -i ~/.ssh/id_ed25519)
agenix -r                        # re-encrypt after changing secrets.nix
```

Declare a new secret in `secrets.nix`, encrypted to `admins ++ [ host ]`, then
give the machine `age.secrets.<name>.file = ./secrets/<name>.age;` in `host.nix`.

### Rotating the GitHub token

A fine-grained personal access token with **Contents: read-only** on this
repository. Before it expires, write `access-tokens = github.com=<new token>` to
`secrets/github-token.age` with `agenix -e`, push, and wait for the machine to
pick it up before revoking the old one.
