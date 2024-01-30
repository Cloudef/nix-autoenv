# nix-autoenv

nix-direnv alternative that does not need a .direnv metafile

> [!NOTE]
> nix-autoenv only works with flake projects.

### How to setup?

Run the following command and put the output in your shell's rc file:
```
# Fish
nix-autoenv fish-setup
# Zsh
nix-autoenv zsh-setup
# Bash
nix-autoenv bash-setup
```

### How does it work?

nix-autoenv runs `nix flake info` on every cd, if it fails to run it will restore the environment,
if it succeeds, it will run `nix develop` inside `bwrap` sandbox and extracts the environment into your current shell.
