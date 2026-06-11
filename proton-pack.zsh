#!/usr/bin/env zsh
# proton-pack — switch Claude Code profiles + stacked Max accounts, by directory.
# MIT licensed. Source from ~/.zshrc:   source /path/to/proton-pack.zsh
#
# TWO AXES
#   PROFILE  which workspace you're in (config dir + git identity + gh user),
#            chosen automatically from your current directory. Keeps separate
#            accounts/orgs from crossing.
#   ACCOUNT  which Anthropic login provides usage. Each profile can stack
#            several Max plans; switch with `pp flip` when one hits its limit.
#
# Define profiles in $PP_PROFILES_FILE (see profiles.conf.example).
# Account tokens live in $PP_ACCOUNTS_DIR/<profile>/<name>.token (0600).

[ -n "$ZSH_VERSION" ] || { print -r -- "proton-pack: requires zsh" >&2; return 1 2>/dev/null; }

: ${PP_CONFIG_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/proton-pack}
: ${PP_PROFILES_FILE:=$PP_CONFIG_DIR/profiles.conf}
: ${PP_ACCOUNTS_DIR:=$PP_CONFIG_DIR/accounts}

# ---- small helpers -------------------------------------------------------
_pp_trim() { local x="$1"; x="${x#"${x%%[![:space:]]*}"}"; x="${x%"${x##*[![:space:]]}"}"; print -r -- "$x"; }

# Reject unsafe account names (path traversal, flag-like, reserved). Allowed:
# letters, digits, dot, underscore, dash; not empty, '.', '..', '-...', 'native'.
_pp_valid_name() {
  case "$1" in
    ""|native|.|..) return 1 ;;
    -*)                return 1 ;;
    *..*)              return 1 ;;
    *[^A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# ---- profile config ------------------------------------------------------
typeset -gA PP_CFG_DIR PP_GIT_NAME PP_GIT_EMAIL PP_GH PP_GLOBS
typeset -ga PP_ORDER
typeset -g  PP_DEFAULT_PROFILE

# Load profiles.conf:  name | config_dir | git_name | git_email | gh_user | globs
_pp_load() {
  PP_ORDER=(); PP_DEFAULT_PROFILE=""
  PP_CFG_DIR=(); PP_GIT_NAME=(); PP_GIT_EMAIL=(); PP_GH=(); PP_GLOBS=()
  [ -r "$PP_PROFILES_FILE" ] || return 0
  local line name cfg gname gemail gh globs
  local -a f
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    f=("${(@s:|:)line}")
    name="$(_pp_trim "${f[1]}")"
    cfg="$(_pp_trim "${f[2]}")"
    gname="$(_pp_trim "${f[3]}")"
    gemail="$(_pp_trim "${f[4]}")"
    gh="$(_pp_trim "${f[5]}")"
    globs="$(_pp_trim "${f[6]}")"
    [ -z "$name" ] && continue
    cfg="${cfg/#\~/$HOME}"
    PP_ORDER+=("$name")
    PP_CFG_DIR[$name]="$cfg"
    PP_GIT_NAME[$name]="$gname"
    PP_GIT_EMAIL[$name]="$gemail"
    PP_GH[$name]="$gh"
    PP_GLOBS[$name]="$globs"
    case " $globs " in *" default "*) [ -z "$PP_DEFAULT_PROFILE" ] && PP_DEFAULT_PROFILE="$name" ;; esac
  done < "$PP_PROFILES_FILE"
  [ -z "$PP_DEFAULT_PROFILE" ] && [ ${#PP_ORDER} -gt 0 ] && PP_DEFAULT_PROFILE="${PP_ORDER[1]}"
}
_pp_load

# Resolve $PWD to a profile name. Profiles are tried in file order; the first
# whose glob matches wins; otherwise the default profile.
_pp_profile_for_pwd() {
  local name pat
  for name in $PP_ORDER; do
    for pat in ${=PP_GLOBS[$name]}; do
      [ "$pat" = default ] && continue
      pat="${pat/#\~/$HOME}"
      case "$PWD" in ${~pat}) print -r -- "$name"; return 0 ;; esac
    done
  done
  print -r -- "$PP_DEFAULT_PROFILE"
}

# ---- account store -------------------------------------------------------
_pp_area_dir()   { print -r -- "$PP_ACCOUNTS_DIR/$1"; }
_pp_token_file() { print -r -- "$PP_ACCOUNTS_DIR/$1/$2.token"; }

# Ensure the store + a profile dir exist and are private (0700).
_pp_ensure_dir() {
  [ -d "$PP_ACCOUNTS_DIR" ]    || mkdir -p "$PP_ACCOUNTS_DIR"
  [ -d "$PP_ACCOUNTS_DIR/$1" ] || mkdir -p "$PP_ACCOUNTS_DIR/$1"
  chmod 700 "$PP_ACCOUNTS_DIR" "$PP_ACCOUNTS_DIR/$1" 2>/dev/null
}

_pp_active() {
  local f="$PP_ACCOUNTS_DIR/$1/.active"
  [ -r "$f" ] && cat "$f" || print -r -- native
}

_pp_set_active() {
  _pp_ensure_dir "$1"
  print -r -- "$2" > "$PP_ACCOUNTS_DIR/$1/.active"
}

# List account names for a profile: native first, then stored token files.
_pp_list() {
  print -r -- native
  local f
  for f in "$PP_ACCOUNTS_DIR/$1"/*.token(N); do
    print -r -- "${${f:t}:r}"
  done
}

# Advance the active account to the next in the list (wrapping). Echoes it.
_pp_rotate() {
  local prof="$1"
  local -a accts; accts=(${(f)"$(_pp_list "$prof")"})
  local cur; cur="$(_pp_active "$prof")"
  local n=${#accts[@]} i idx=1
  for (( i=1; i<=n; i++ )); do [ "${accts[$i]}" = "$cur" ] && { idx=$i; break; }; done
  local next="${accts[$(( idx % n + 1 ))]}"
  _pp_set_active "$prof" "$next"
  print -r -- "$next"
}

# ---- launch --------------------------------------------------------------
# Inject the profile's env (config dir, git identity) and — if a stacked
# account is active — its OAuth token, then run claude. All vars are `local -x`,
# so they reach the launched process but are unset on return and never linger
# in your shell or appear in any process's argv.
_pp_launch() {
  local prof; prof="$(_pp_profile_for_pwd)"
  if [ -z "$prof" ]; then
    print -r -- "proton-pack: no profile for $PWD and no default set — edit $PP_PROFILES_FILE" >&2
    command claude "$@"; return
  fi
  local cfg="${PP_CFG_DIR[$prof]}" gname="${PP_GIT_NAME[$prof]}" gemail="${PP_GIT_EMAIL[$prof]}" gh="${PP_GH[$prof]}"
  [ -n "$gh" ] && [ "$gh" != - ] && command -v gh >/dev/null 2>&1 && gh auth switch --user "$gh" >/dev/null 2>&1
  [ -n "$cfg" ]    && [ "$cfg" != - ]    && local -x CLAUDE_CONFIG_DIR="$cfg"
  [ -n "$gname" ]  && [ "$gname" != - ]  && local -x GIT_AUTHOR_NAME="$gname" GIT_COMMITTER_NAME="$gname"
  [ -n "$gemail" ] && [ "$gemail" != - ] && local -x GIT_AUTHOR_EMAIL="$gemail" GIT_COMMITTER_EMAIL="$gemail"
  local acct; acct="$(_pp_active "$prof")"
  if [ "$acct" != native ] && _pp_valid_name "$acct"; then
    local tf; tf="$(_pp_token_file "$prof" "$acct")"
    if [ -r "$tf" ]; then
      local -x CLAUDE_CODE_OAUTH_TOKEN="$(cat "$tf")"
    else
      print -r -- "proton-pack: account '$acct' for '$prof' has no token; using native login" >&2
    fi
  fi
  command claude "$@"
}

# The magic: `claude` auto-selects profile+account from your directory.
# Set PP_NO_WRAP=1 before sourcing if you'd rather keep `claude` untouched and
# launch via `pp run` instead.
if [ -z "${PP_NO_WRAP:-}" ]; then
  claude() {
    if [ -n "$CLAUDE_CONFIG_DIR" ]; then command claude "$@"; return; fi
    _pp_launch "$@"
  }
fi

# ---- pp: management command ----------------------------------------------
_pp_show_profiles() {
  if [ ${#PP_ORDER} -eq 0 ]; then
    print -r -- "no profiles configured. Edit $PP_PROFILES_FILE (see profiles.conf.example)."; return 1
  fi
  local cur; cur="$(_pp_profile_for_pwd)"
  print -r -- "profiles (from $PP_PROFILES_FILE):"
  local name mark
  for name in $PP_ORDER; do
    mark="  "; [ "$name" = "$cur" ] && mark=" *"
    printf '%s %-12s -> %s\n' "$mark" "$name" "${PP_CFG_DIR[$name]}"
  done
  print -r -- "( * = selected for the current directory )"
}

_pp_where() {
  local prof; prof="$(_pp_profile_for_pwd)"
  [ -z "$prof" ] && { print -r -- "no profile matches $PWD and no default is set."; return 1; }
  printf '%-12s -> %s\n' "$prof" "${PP_CFG_DIR[$prof]}"
  printf '   git: %s <%s>   gh: %s   account: %s\n' \
    "${PP_GIT_NAME[$prof]:--}" "${PP_GIT_EMAIL[$prof]:--}" "${PP_GH[$prof]:--}" "$(_pp_active "$prof")"
}

_pp_show_accounts() {
  local prof="$1"
  [ -z "$prof" ] && { print -r -- "no profile for $PWD"; return 1; }
  local cur; cur="$(_pp_active "$prof")"
  print -r -- "profile: $prof    accounts dir: $(_pp_area_dir "$prof")"
  local a
  for a in ${(f)"$(_pp_list "$prof")"}; do
    if [ "$a" = "$cur" ]; then print -r -- "  * $a   (active)"; else print -r -- "    $a"; fi
  done
}

_pp_use() {
  local prof="$1" name="$2"
  [ -z "$prof" ] && { print -r -- "pp: no profile for $PWD"; return 1; }
  [ -z "$name" ] && { print -r -- "usage: pp use <name>"; return 1; }
  if [ "$name" != native ] && ! _pp_valid_name "$name"; then
    print -r -- "pp: invalid account name '$name' (letters, digits, . _ - only)"; return 1
  fi
  if [ "$name" != native ] && [ ! -r "$(_pp_token_file "$prof" "$name")" ]; then
    print -r -- "pp: no token for '$name' in '$prof' (add it: pp add $name)"; return 1
  fi
  _pp_set_active "$prof" "$name"
  print -r -- "✓ $prof active account -> $name"
}

_pp_flip() {
  local prof="$1"
  [ -z "$prof" ] && { print -r -- "pp: no profile for $PWD"; return 1; }
  local -a accts; accts=(${(f)"$(_pp_list "$prof")"})
  if [ ${#accts[@]} -le 1 ]; then
    print -r -- "pp flip: only 'native' exists for '$prof'. Stack another: pp add <name>"; return 1
  fi
  local prev; prev="$(_pp_active "$prof")"
  local next; next="$(_pp_rotate "$prof")"
  print -r -- "✓ $prof account: $prev → $next  (now active)"
  print -r -- "  resume your work:  claude --resume"
}

_pp_remove() {
  local prof="$1" name="$2"
  [ -z "$name" ] && { print -r -- "usage: pp rm <name>"; return 1; }
  [ "$name" = native ] && { print -r -- "pp: can't remove the native login"; return 1; }
  if ! _pp_valid_name "$name"; then print -r -- "pp: invalid account name '$name'"; return 1; fi
  rm -f "$(_pp_token_file "$prof" "$name")" && print -r -- "✓ removed account '$name' from '$prof'"
  [ "$(_pp_active "$prof")" = "$name" ] && { _pp_set_active "$prof" native; print -r -- "  (was active; reset to native)"; }
}

# Mint a long-lived OAuth token in a throwaway config dir (so existing logins
# stay untouched), then store it chmod 600 for this profile.
_pp_add_account() {
  local prof="$1" name="$2"
  [ -z "$prof" ] && { print -r -- "pp: no profile for $PWD"; return 1; }
  if ! _pp_valid_name "$name"; then
    print -r -- "pp: invalid account name '$name'."
    print -r -- "  Use letters, digits, dot, underscore, or dash (no '/', '..', or 'native')."
    return 1
  fi
  local tf; tf="$(_pp_token_file "$prof" "$name")"
  [ -e "$tf" ] && { print -r -- "pp: account '$name' already exists for '$prof'. Remove it first (pp rm $name)."; return 1; }
  _pp_ensure_dir "$prof"
  print -r -- "Minting an OAuth token for account '$name' (profile: $prof)."
  print -r -- "A browser login opens in a SEPARATE temp config dir — your other logins"
  print -r -- "are untouched. Sign in as the account you want to stack here."
  print -r -- "(Tip: use a private/incognito window so you don't reuse another login.)"
  print -r -- ""
  local tmp; tmp="$(mktemp -d)"
  CLAUDE_CONFIG_DIR="$tmp" command claude setup-token
  print -r -- ""
  print -r -- "Paste the sk-ant-oat... token printed above (hidden), then Enter:"
  local tok; read -rs tok; print -r -- ""
  rm -rf "$tmp"
  tok="${tok//[[:space:]]/}"
  if [[ "$tok" != sk-ant-oat* ]]; then
    print -r -- "That doesn't look like an OAuth token (expected sk-ant-oat...). Aborted."; return 1
  fi
  ( umask 077; print -r -- "$tok" > "$tf" )
  chmod 600 "$tf"
  print -r -- "✓ stored -> $tf (chmod 600)"
  print -r -- "⚠ setup-token printed the token to this terminal — it's in your scrollback."
  print -r -- "  Run 'clear' (and clear any tmux/terminal logging) to scrub it."
  print -r -- "  activate: pp use $name    |    next account: pp flip"
}

_pp_doctor() {
  print -r -- "proton-pack doctor"
  print -r -- "  config file: $PP_PROFILES_FILE $([ -r "$PP_PROFILES_FILE" ] && print -r -- '(ok)' || print -r -- '(MISSING)')"
  print -r -- "  profiles:    ${#PP_ORDER}    default: ${PP_DEFAULT_PROFILE:-<none>}"
  if command -v claude >/dev/null 2>&1; then print -r -- "  claude:      $(command -v claude)"; else print -r -- "  claude:      NOT FOUND in PATH"; fi
  if command -v gh >/dev/null 2>&1; then print -r -- "  gh:          $(command -v gh)"; else print -r -- "  gh:          not installed (gh switching is skipped)"; fi
  local name d
  for name in $PP_ORDER; do
    d="${PP_CFG_DIR[$name]}"
    print -r -- "  profile '$name': $d $([ -d "$d" ] && print -r -- exists || print -r -- '(created on first use)')"
  done
  if [ -d "$PP_ACCOUNTS_DIR" ]; then
    local p; p="$(stat -f '%Lp' "$PP_ACCOUNTS_DIR" 2>/dev/null || stat -c '%a' "$PP_ACCOUNTS_DIR" 2>/dev/null)"
    print -r -- "  accounts dir: $PP_ACCOUNTS_DIR (perms $p $([ "$p" = 700 ] && print -r -- ok || print -r -- 'want 700'))"
  fi
}

_pp_help() {
  cat <<'EOF'
proton-pack — Claude Code profile + account switching, by directory

  claude [args]     launch Claude in the profile + account for this directory
  pp profiles       list configured profiles (the one for this dir marked *)
  pp where          show profile + account for the current directory
  pp ls             list accounts for the current profile
  pp add <name>     add a stacked account (opens a browser login)
  pp use <name>     switch the active account
  pp flip           rotate to the next account (no launch); then `claude --resume`
  pp rm <name>      remove a stored account
  pp run [args]     launch (same as `claude`; use when the wrapper is disabled)
  pp reload         re-read profiles.conf after editing it
  pp doctor         check config, perms, and dependencies
  pp help           this help

Accounts: 'native' is each profile's built-in login; stack more as b, c, d ...
Profiles live in ~/.config/proton-pack/profiles.conf (see profiles.conf.example).
EOF
}

pp() {
  local cmd="$1"; [ $# -gt 0 ] && shift
  local prof; prof="$(_pp_profile_for_pwd)"
  case "$cmd" in
    ""|help|-h|--help) _pp_help ;;
    profiles)          _pp_show_profiles ;;
    where|profile)     _pp_where ;;
    ls|list|accounts)  _pp_show_accounts "$prof" ;;
    add)               _pp_add_account "$prof" "$1" ;;
    use)               _pp_use "$prof" "$1" ;;
    flip|rotate)       _pp_flip "$prof" ;;
    rm|remove)         _pp_remove "$prof" "$1" ;;
    run)               _pp_launch "$@" ;;
    reload)            _pp_load && print -r -- "reloaded ${#PP_ORDER} profiles from $PP_PROFILES_FILE" ;;
    doctor)            _pp_doctor ;;
    *) print -r -- "pp: unknown command '$cmd' (try: pp help)"; return 1 ;;
  esac
}
