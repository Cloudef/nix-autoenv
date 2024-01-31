{
   lib
   , writeShellApplication
   , writeShellScript
   , coreutils
   , gnugrep
   , gnused
   , bubblewrap
   , jq
   , git
   , nix
   , bundleNix ? false
   , targetPlatform
}:

with builtins;
with lib;

let
   # Not a writeShellApplication because it mangles PATH
   # These commands do not try to handle env vars that contain single quotes
   # Escaping these portably for every shell is PITA
   envget-sorted = writeShellScript "envget-w-keys" ''
      PATH="$__nix_autoenv_real_path" \
      ${coreutils}/bin/env -u PWD -u SHLVL -u _ -u TEMP -u TEMPDIR -u TMPDIR -u TMP -0 |\
         ${gnugrep}/bin/grep -zv __nix_autoenv_ | ${gnugrep}/bin/grep -zv "'" | ${coreutils}/bin/sort -zu > "$1"
      '';
   envget = writeShellScript "envget" ''
      PATH="$__nix_autoenv_real_path" \
      ${coreutils}/bin/env -u PWD -u SHLVL -u _ -u TEMP -u TEMPDIR -u TMPDIR -u TMP \
         -u __nix_autoenv_real_path -u __nix_autoenv_prev_pwd -0 |\
         ${gnugrep}/bin/grep -zv "'"
      '';

   # Do not pass to writeShellApplication since we want to preserve real path
   runtimeInputs = [ bubblewrap coreutils gnugrep gnused jq git ] ++ optionals (bundleNix) [ nix ];
in writeShellApplication {
   name = "nix-autoenv";
   text = ''
      export __nix_autoenv_real_path="$PATH"
      export PATH="${makeBinPath runtimeInputs}:$PATH"
      ${if bundleNix then "NIX=nix" else ''NIX="$(readlink /var/run/current-system/sw/bin/nix)"''}
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
         # do not use IFS='=' because it gobbles other = characters
         while IFS="" read -d $'\0' -r var; do
            k="''${var%%=*}"
            v="''${var#*=}"
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
         # do not use IFS='=' because it gobbles other = characters
         while IFS="" read -d $'\0' -r var; do
            k="''${var%%=*}"
            v="''${var#*=}"
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
         ${envget} | grep -z __nix_autoenv_saved_ | sed -z 's/__nix_autoenv_saved_//' | $2 0 || true
         ${envget} | grep -z __nix_autoenv_ | $1 || true
      }

      shell_env() {
         echo 'nix-autoenv: Generating dev shell environment using bwrap ...' 1>&2
         nix_cache="''${XDG_CONFIG_CACHE:-$HOME/.cache}/nix"
         time bwrap --unshare-all --share-net --die-with-parent \
            --tmpfs /tmp \
            --bind "$tmpdir" "$tmpdir" \
            --dev-bind /dev/null /dev/null \
            --dev-bind /dev/stdin /dev/stdin \
            --dev-bind /dev/stdout /dev/stdout \
            --dev-bind /dev/stderr /dev/stderr \
            --proc /proc \
            --ro-bind-try /etc/hosts /etc/hosts \
            --ro-bind-try /etc/static/hosts /etc/static/hosts \
            --ro-bind-try /etc/ssl /etc/ssl \
            --ro-bind-try /etc/static/ssl /etc/static/ssl \
            --ro-bind-try /etc/nix /etc/nix \
            --ro-bind-try /etc/static/nix /etc/static/nix \
            --bind "$nix_cache" "$nix_cache" \
            --bind /nix /nix \
            --ro-bind "$1" "$1" \
            "$NIX" \
               --extra-experimental-features nix-command \
               --extra-experimental-features flakes \
               --quiet develop "$2" -c sh ${envget-sorted} "$tmpdir/env" 1>/dev/null 2>"$tmpdir/error"
         ret=$?
         grep -v 'error: flake .* does not provide attribute' "$tmpdir/error" 1>&2
         return $ret
      }

      flake_env() {
         if "$NIX" flake info --json 1>"$tmpdir/info" 2>/dev/null; then
            url=$(jq -r '.original.url' "$tmpdir/info")
            path="''${url/file:\/\//}"
            if shell_env "$path" "$3"; then
               restore_env "$1" "$2"
               ${envget-sorted} "$tmpdir/orig"
               comm --check-order -z23 "$tmpdir/env" "$tmpdir/orig" | $2
               printf '__nix_autoenv_flake_url=%s\0__nix_autoenv_flake_shell=%s\0' "$url" "$3" | $2 0
               if git status --porcelain=v2 2>/dev/null | (grep -Po '.*(?=\s+[^\s]+$)' 2>/dev/null || true) > "$tmpdir/git-state"; then
                  git_state="$("$NIX" hash file "$tmpdir/git-state")"
                  printf '__nix_autoenv_flake_git_state=%s\0' "$git_state" | $2 0
               fi
            fi
         fi
      }

      flake_detect() {
         if "$NIX" flake info --json 1>"$tmpdir/info" 2>/dev/null; then
            url=$(jq -r '.original.url' "$tmpdir/info")
            if [[ "$url" != "''${__nix_autoenv_flake_url:-}" ]]; then
               if [[ ''${NIX_AUTOENV_AUTO:-0} == 1 ]]; then
                  flake_env "$1" "$2" .
               else
                  printf '__nix_autoenv_flake_url=%s\0' "$url" | $2 0
                  # shellcheck disable=SC2016
                  echo 'nix-autoenv: Use `nix-autoenv switch [dev shell]` to switch to an dev environment' 1>&2
               fi
            else
               if git status --porcelain=v2 2>/dev/null | (grep -Po '.*(?=\s+[^\s]+$)' 2>/dev/null || true) > "$tmpdir/git-state"; then
                  git_state="$("$NIX" hash file "$tmpdir/git-state")"
                  if [[ "$git_state" != "''${__nix_autoenv_flake_git_state:-}" ]] && [[ "''${__nix_autoenv_flake_shell:-}" ]]; then
                     printf 'nix-autoenv: Changes detected %s != %s ...\n' "$git_state" "''${__nix_autoenv_flake_git_state:-none}" 1>&2
                     flake_env "$1" "$2" "$__nix_autoenv_flake_shell"
                  fi
                  printf '__nix_autoenv_flake_git_state=%s\0' "$git_state" | $2 0
               fi
            fi
         elif is_in_flake; then
            echo 'nix-autoenv: Restoring environment ...' 1>&2
            restore_env "$1" "$2"
         fi
      }

      case "''${1:-}" in
         fish-setup)
            printf 'source (${placeholder "out"}/bin/nix-autoenv fish-source | psub)\n'
            ;;
         fish-source)
            cat <<'EOF'
      function nix-autoenv -a cmd --wraps=nix-autoenv -d "nix-autoenv fish wrapper"
         if test "$cmd" = "switch"
            source (${placeholder "out"}/bin/nix-autoenv fish-export "$1" | psub)
         else
            ${placeholder "out"}/bin/nix-autoenv "$argv"
         end
      end
      function _nix_autoenv_cd --on-variable PWD
         source (${placeholder "out"}/bin/nix-autoenv fish-detect | psub)
      end
      EOF
            ;;
         fish-detect)
            flake_detect unset_fish export_fish
            ;;
         fish-export)
            flake_env unset_fish export_fish ".#''${2:-}"
            ;;
         bash-setup)
            printf 'source <(${placeholder "out"}/bin/nix-autoenv bash-source)\n'
            ;;
         bash-source)
            cat <<'EOF'
      nix-autoenv() {
         if [[ "$1" == "switch" ]]; then
            source <(${placeholder "out"}/bin/nix-autoenv bash-export "$2")
         else
            ${placeholder "out"}/bin/nix-autoenv "$@"
         fi
      }
      _nix_autoenv_cd() {
         if [[ "$__nix_autoenv_prev_pwd" != "$PWD" ]]; then
            source <(${placeholder "out"}/bin/nix-autoenv bash-detect)
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
      nix-autoenv() {
         if [[ "$1" == "switch" ]]; then
            source <(${placeholder "out"}/bin/nix-autoenv zsh-export "$2")
         else
            ${placeholder "out"}/bin/nix-autoenv "$@"
         fi
      }
      autoload -U add-zsh-hook
      add-zsh-hook -Uz chpwd (){ source <(${placeholder "out"}/bin/nix-autoenv zsh-detect); }
      EOF
            ;;
         *sh-detect)
            flake_detect unset_sh export_sh
            ;;
         *sh-export)
            flake_env unset_sh export_sh ".#''${2:-}"
            ;;
         *)
            printf 'usage: nix-autoenv [bash | fish | zsh | ... ]\n' 1>&2
            ;;
      esac
      '';
}
