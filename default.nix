{
   lib
   , writeShellApplication
   , writeShellScript
   , coreutils
   , gnugrep
   , gnused
   , bubblewrap
   , jq
   , nix
   , bundleNix ? false
}:

with builtins;
with lib;

let
   # Not a writeShellApplication because it mangles PATH
   # These commands do not try to handle env vars that contain single quotes
   # Escaping these portably for every shell is PITA
   envget-sorted = writeShellScript "envget-w-keys" ''
      ${coreutils}/bin/env -u PWD -u SHLVL -u _ -u TEMP -u TEMPDIR -u TMPDIR -u TMP -0 |\
      while IFS='=' read -d $'\0' -r k v; do
         printf '%s=%s\0' "$k" "$v"
      done | ${gnugrep}/bin/grep -zv __nix_autoenv_saved_ | ${gnugrep}/bin/grep -zv "'" | ${coreutils}/bin/sort -zu > "$1"
      '';
   envget = writeShellScript "envget" ''
      ${coreutils}/bin/env -u PWD -u SHLVL -u _ -u TEMP -u TEMPDIR -u TMPDIR -u TMP -0 |\
      while IFS='=' read -d $'\0' -r k v; do
         printf '%s=%s\0' "$k" "$v"
      done | ${gnugrep}/bin/grep -zv "'"
      '';
in writeShellApplication {
   name = "nix-autoenv";
   runtimeInputs = [ bubblewrap coreutils gnugrep gnused jq ] ++ optionals (bundleNix) [ nix ];
   text = ''
      tmpdir="$(mktemp -d)"
      trap 'rm -rf "$tmpdir"' EXIT

      is_in_flake() {
         test "''${__nix_autoenv_flake_url:-}" != ""
      }

      unset_sh() {
         while IFS='=' read -d $'\0' -r k _; do
            printf 'unset %s\n' "$k"
         done
      }

      export_sh() {
         while IFS='=' read -d $'\0' -r k v; do
            if [[ "''${1:-}" != 0 ]] && [[ "''${!k:-}" != "$v" ]]; then
               printf "export %s__nix_autoenv_saved_='%s'\n" "$k" "''${!k:-}"
            fi
            if [[ "$v" != "" ]]; then
               printf "export %s='%s'\n" "$k" "$v"
            else
               printf 'unset %s\n' "$k"
            fi
         done
      }

      unset_fish() {
         while IFS='=' read -d $'\0' -r k _; do
            printf 'set -e %s\n' "$k"
         done
      }

      export_fish() {
         while IFS='=' read -d $'\0' -r k v; do
            if [[ "''${1:-}" != 0 ]] && [[ "''${!k:-}" != "$v" ]]; then
               printf "set -gx %s__nix_autoenv_saved_ '%s'\n" "$k" "''${!k:-}"
            fi
            if [[ "$v" != "" ]]; then
               printf "set -gx %s '%s'\n" "$k" "$v"
            else
               printf 'set -e %s\n' "$k"
            fi
         done
      }

      restore_env() {
         ${envget} | grep -z __nix_autoenv_saved_ | $1 || true
         ${envget} | grep -z __nix_autoenv_saved_ | sed -z 's/__nix_autoenv_saved_//' | $2 0 || true
      }

      shell_env() {
         echo 'nix-autoenv: generating devshell using bwrap ...' 1>&2
         nix_cache="''${XDG_CONFIG_CACHE:-$HOME/.cache}/nix"
         ${if bundleNix then "NIX=nix" else "NIX=/var/run/current-system/sw/bin/nix"}
         time bwrap --unshare-all --share-net --die-with-parent \
            --ro-bind / / \
            --bind /tmp /tmp \
            --dev-bind /dev /dev \
            --bind "$nix_cache" "$nix_cache" \
            --bind /nix /nix \
            $NIX --quiet develop -c sh ${envget-sorted} "$tmpdir/env" 1>/dev/null 2>"$tmpdir/error"
         ret=$?
         grep -v 'error: flake .* does not provide attribute' "$tmpdir/error" 1>&2
         return $ret
      }

      flake_env() {
         if nix flake info --json 1>"$tmpdir/info" 2>/dev/null; then
            flake="$(jq -r .url "$tmpdir/info")"
            if [[ "$flake" != "''${__nix_autoenv_flake_url:-}" ]]; then
               if __nix_autoenv_flake_url="$flake" shell_env; then
                  restore_env "$1" "$2"
                  ${envget-sorted} "$tmpdir/orig"
                  comm --check-order -z23 "$tmpdir/env" "$tmpdir/orig" | $2
               elif is_in_flake; then
                  restore_env "$1" "$2"
               fi
            fi
         elif is_in_flake; then
            restore_env "$1" "$2"
         fi
      }

      case "''${1:-}" in
         fish-setup)
            printf 'source (${placeholder "out"}/bin/nix-autoenv fish-source | psub)\n'
            ;;
         fish-source)
            cat <<'EOF'
      function _nix_autoenv_cd --on-variable PWD
         source (${placeholder "out"}/bin/nix-autoenv fish | psub)
      end
      EOF
            ;;
         fish)
            flake_env unset_fish export_fish
            ;;
         bash-setup)
            printf 'source <(${placeholder "out"}/bin/nix-autoenv bash-source)\n'
            ;;
         bash-source)
            cat <<'EOF'
      _nix_autoenv_cd() {
         if [[ "$__nix_autoenv_prev_pwd" != "$PWD" ]]; then
            source <(${placeholder "out"}/bin/nix-autoenv bash)
         fi
         export __nix_autoenv_prev_pwd="$PWD"
      }
      PROMPT_COMMAND="_nix_autoenv_cd''${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
      EOF
            ;;
         zsh-setup)
            printf 'source <(${placeholder "out"}/bin/nix-autoenv zsh-source)\n'
            ;;
         zsh-source)
            cat <<'EOF'
      autoload -U add-zsh-hook
      add-zsh-hook -Uz chpwd (){ source <(${placeholder "out"}/bin/nix-autoenv zsh); }
      EOF
            ;;
         *sh)
            flake_env unset_sh export_sh
            ;;
         *)
            printf 'usage: nix-autoenv [bash | fish | zsh | ... ]\n' 1>&2
            ;;
      esac
      '';
}
