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
#            Two types: a 'token' account (cheap, inference-only) or a 'login'
#            sub-profile (its own config dir + full login -> Remote Control / MCP
#            auth work). See `pp add` vs `pp add-login`.
#
# Define profiles in $PP_PROFILES_FILE (see profiles.conf.example).
# Account store: $PP_ACCOUNTS_DIR/<profile>/<name>.token  (token, 0600)
#                $PP_ACCOUNTS_DIR/<profile>/<name>.login  (sub-profile dir path)

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
_pp_area_dir()     { print -r -- "$PP_ACCOUNTS_DIR/$1"; }
_pp_token_file()   { print -r -- "$PP_ACCOUNTS_DIR/$1/$2.token"; }
_pp_login_marker() { print -r -- "$PP_ACCOUNTS_DIR/$1/$2.login"; }

# Type of an account for a profile: native | token | login | unknown.
_pp_acct_type() {
  [ "$2" = native ] && { print -r -- native; return; }
  [ -r "$(_pp_login_marker "$1" "$2")" ] && { print -r -- login; return; }
  [ -r "$(_pp_token_file "$1" "$2")" ]   && { print -r -- token; return; }
  print -r -- unknown
}

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

# List account names for a profile: native first, then token + login accounts
# (deduped, in case a name somehow has both).
_pp_list() {
  local -a names; names=(native)
  local f
  for f in "$PP_ACCOUNTS_DIR/$1"/*.token(N) "$PP_ACCOUNTS_DIR/$1"/*.login(N); do
    names+=("${${f:t}:r}")
  done
  print -rl -- "${(u)names[@]}"
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

  # Account axis (resolved before env so a login sub-profile can override cfg):
  #   login -> route to the sub-profile's own config dir (full-scope login)
  #   token -> keep the profile's config dir, inject the OAuth token
  local acct; acct="$(_pp_active "$prof")"
  local use_token=""
  if [ "$acct" != native ] && _pp_valid_name "$acct"; then
    local lf tf; lf="$(_pp_login_marker "$prof" "$acct")"; tf="$(_pp_token_file "$prof" "$acct")"
    if [ -r "$lf" ]; then
      local ld; ld="$(command cat "$lf")"
      if [ -d "$ld" ]; then cfg="$ld"
      else print -r -- "proton-pack: login sub-profile '$acct' dir missing ($ld); using native login" >&2; fi
    elif [ -r "$tf" ]; then
      use_token="$tf"
    else
      print -r -- "proton-pack: account '$acct' for '$prof' has no token or login dir; using native login" >&2
    fi
  fi

  [ -n "$gh" ] && [ "$gh" != - ] && command -v gh >/dev/null 2>&1 && gh auth switch --user "$gh" >/dev/null 2>&1
  [ -n "$cfg" ]    && [ "$cfg" != - ]    && local -x CLAUDE_CONFIG_DIR="$cfg"
  [ -n "$gname" ]  && [ "$gname" != - ]  && local -x GIT_AUTHOR_NAME="$gname" GIT_COMMITTER_NAME="$gname"
  [ -n "$gemail" ] && [ "$gemail" != - ] && local -x GIT_AUTHOR_EMAIL="$gemail" GIT_COMMITTER_EMAIL="$gemail"
  [ -n "$use_token" ] && local -x CLAUDE_CODE_OAUTH_TOKEN="$(cat "$use_token")"
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
  local a t tag
  for a in ${(f)"$(_pp_list "$prof")"}; do
    t="$(_pp_acct_type "$prof" "$a")"
    case "$t" in
      native) tag="native login (full scope)" ;;
      token)  tag="token (inference-only)" ;;
      login)  tag="login sub-profile (full scope)" ;;
      *)      tag="$t" ;;
    esac
    if [ "$a" = "$cur" ]; then print -r -- "  * $a   — $tag   (active)"; else print -r -- "    $a   — $tag"; fi
  done
}

_pp_use() {
  local prof="$1" name="$2"
  [ -z "$prof" ] && { print -r -- "pp: no profile for $PWD"; return 1; }
  [ -z "$name" ] && { print -r -- "usage: pp use <name>"; return 1; }
  if [ "$name" != native ] && ! _pp_valid_name "$name"; then
    print -r -- "pp: invalid account name '$name' (letters, digits, . _ - only)"; return 1
  fi
  if [ "$name" != native ] && [ ! -r "$(_pp_token_file "$prof" "$name")" ] && [ ! -r "$(_pp_login_marker "$prof" "$name")" ]; then
    print -r -- "pp: no account '$name' in '$prof' (token: pp add $name | login sub-profile: pp add-login $name)"; return 1
  fi
  _pp_set_active "$prof" "$name"
  print -r -- "✓ $prof active account -> $name ($(_pp_acct_type "$prof" "$name"))"
}

_pp_flip() {
  local prof="$1"
  [ -z "$prof" ] && { print -r -- "pp: no profile for $PWD"; return 1; }
  local -a accts; accts=(${(f)"$(_pp_list "$prof")"})
  if [ ${#accts[@]} -le 1 ]; then
    print -r -- "pp flip: only 'native' exists for '$prof'. Stack another: pp add <name> | pp add-login <name>"; return 1
  fi
  local prev; prev="$(_pp_active "$prof")"
  local next; next="$(_pp_rotate "$prof")"
  local nt; nt="$(_pp_acct_type "$prof" "$next")"
  print -r -- "✓ $prof account: $prev → $next ($nt)  (now active)"
  if [ "$nt" = login ]; then
    print -r -- "  full-scope sub-profile — its own session space; Remote Control works."
    print -r -- "  resume there:  claude --resume   (start fresh if it's empty)"
  else
    print -r -- "  resume your work:  claude --resume"
  fi
}

_pp_remove() {
  local prof="$1" name="$2"
  [ -z "$name" ] && { print -r -- "usage: pp rm <name>"; return 1; }
  [ "$name" = native ] && { print -r -- "pp: can't remove the native login"; return 1; }
  if ! _pp_valid_name "$name"; then print -r -- "pp: invalid account name '$name'"; return 1; fi
  local lf; lf="$(_pp_login_marker "$prof" "$name")"
  if [ -r "$lf" ]; then
    local ld; ld="$(command cat "$lf")"
    rm -f "$lf" && print -r -- "✓ removed login sub-profile '$name' from '$prof'"
    print -r -- "  its config dir is left intact (still logged in): $ld"
    print -r -- "  to delete it for good:  rm -rf '$ld'"
  else
    rm -f "$(_pp_token_file "$prof" "$name")" && print -r -- "✓ removed account '$name' from '$prof'"
  fi
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

# Inherit a profile's config + personality into a sub-profile dir so the
# sub-account behaves identically — differing ONLY in which account it logs in
# as. Copies settings + MCP servers; replicates every symlink the parent has
# (commands, skills, plugins, agents, statusline, etc. — however your profile is
# wired); copies a per-profile CLAUDE.md. NEVER copies credentials, account
# identity, or session/history. Shared by add-login and capture.
_pp_inherit_config() {
  local parent="$1" sub="$2"
  [ -r "$parent/settings.json" ]       && cp -p "$parent/settings.json"       "$sub/settings.json"
  [ -r "$parent/settings.local.json" ] && cp -p "$parent/settings.local.json" "$sub/settings.local.json"
  [ -r "$parent/.mcp.json" ]           && cp -p "$parent/.mcp.json"           "$sub/.mcp.json"
  [ -f "$parent/CLAUDE.md" ] && [ ! -e "$sub/CLAUDE.md" ] && cp -p "$parent/CLAUDE.md" "$sub/CLAUDE.md"
  if [ -r "$parent/.claude.json" ] && command -v python3 >/dev/null 2>&1; then
python3 - "$parent/.claude.json" "$sub/.claude.json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(src))
except Exception:
    d = {}
out = {}
mcp = d.get("mcpServers")
if isinstance(mcp, dict):
    out["mcpServers"] = mcp
json.dump(out, open(dst, "w"), indent=2)
PY
    chmod 600 "$sub/.claude.json"
  fi
  # Replicate the parent's symlinks (this is how a profile shares one canonical
  # set of commands/skills/plugins/agents across its accounts). A real entry in
  # the sub that collides with a parent symlink is merged into the link target,
  # never dropped.
  local e tgt name
  for e in "$parent"/*(@N) "$parent"/.*(@N); do
    name="${e:t}"; tgt="$(readlink "$e")"
    [ -L "$sub/$name" ] && continue
    if [ -e "$sub/$name" ]; then
      { [ -d "$sub/$name" ] && [ -d "$tgt" ]; } && cp -Rn "$sub/$name/." "$tgt/" 2>/dev/null
      rm -rf "$sub/$name"
    fi
    ln -s "$tgt" "$sub/$name"
  done
}

# Create a full-scope LOGIN sub-profile: a sibling config dir that inherits the
# profile's settings + MCP servers (NOT its credentials), then gets its own
# `claude auth login`. Unlike a token account, it's a real login -> Remote
# Control and MCP OAuth work.
_pp_add_login() {
  local prof="$1" name="$2"
  [ -z "$prof" ] && { print -r -- "pp: no profile for $PWD"; return 1; }
  if ! _pp_valid_name "$name"; then
    print -r -- "pp: invalid account name '$name'."
    print -r -- "  Use letters, digits, dot, underscore, or dash (no '/', '..', or 'native')."
    return 1
  fi
  if [ -e "$(_pp_token_file "$prof" "$name")" ] || [ -e "$(_pp_login_marker "$prof" "$name")" ]; then
    print -r -- "pp: account '$name' already exists for '$prof'. Remove it first (pp rm $name)."; return 1
  fi
  local parent="${PP_CFG_DIR[$prof]}"
  if [ -z "$parent" ] || [ "$parent" = - ]; then
    print -r -- "pp: profile '$prof' has no config dir set in profiles.conf — can't make a sub-profile."; return 1
  fi
  parent="${parent/#\~/$HOME}"
  local sub="${parent}-${name}"
  if [ -e "$sub" ]; then
    print -r -- "pp: sub-profile dir already exists: $sub (pick another name or remove it)."; return 1
  fi
  _pp_ensure_dir "$prof"
  mkdir -p "$sub" && chmod 700 "$sub"
  _pp_inherit_config "$parent" "$sub"

  print -r -- "$sub" > "$(_pp_login_marker "$prof" "$name")"
  chmod 600 "$(_pp_login_marker "$prof" "$name")"

  print -r -- "✓ created login sub-profile '$name' for '$prof'"
  print -r -- "  config dir : $sub"
  print -r -- "  inherited  : settings + MCP servers from $parent (NOT its login)"
  print -r -- ""
  print -r -- "Next — log it in with the OTHER account (full scope, opens a browser):"
  print -r -- "  CLAUDE_CONFIG_DIR=$sub command claude auth login"
  print -r -- "Confirm it's a different account than native:"
  print -r -- "  CLAUDE_CONFIG_DIR=$sub command claude auth status"
  print -r -- "Then activate it here:  pp use $name   (or pp flip)"
}

# macOS: capture a full-scope login into a FILE-BASED sub-profile.
# On macOS, `claude auth login` always writes the ONE shared Keychain slot
# ("Claude Code-credentials") — never a per-dir file — which is why add-login
# can't isolate there. But a config dir holding its own .credentials.json
# (+ .claude.json for identity/MCP) is a complete full-scope login that
# ignores the Keychain entirely. So: create the sub dir, sign in (lands in
# the Keychain), then EXTRACT the Keychain item into the dir. The result is
# parallel-safe alongside every other captured login.
# Tradeoff: the credential lands as a plaintext 0600 file. Reversible —
# delete the dir's .credentials.json and the dir falls back to the Keychain.
_pp_capture() {
  local prof="$1" name="$2"
  case "$OSTYPE" in
    darwin*) ;;
    *)
      print -r -- "pp capture is macOS-only (it extracts the macOS Keychain login)."
      print -r -- "On Linux/Windows, logins are per-dir files already: pp add-login $name"
      return 1 ;;
  esac
  [ -z "$prof" ] && { print -r -- "pp: no profile for $PWD"; return 1; }
  if ! _pp_valid_name "$name"; then
    print -r -- "pp: invalid account name '$name'."
    print -r -- "  Use letters, digits, dot, underscore, or dash (no '/', '..', or 'native')."
    return 1
  fi
  if [ -e "$(_pp_token_file "$prof" "$name")" ] || [ -e "$(_pp_login_marker "$prof" "$name")" ]; then
    print -r -- "pp: account '$name' already exists for '$prof'. Remove it first (pp rm $name)."; return 1
  fi
  local parent="${PP_CFG_DIR[$prof]}"
  if [ -z "$parent" ] || [ "$parent" = - ]; then
    print -r -- "pp: profile '$prof' has no config dir set in profiles.conf — can't make a sub-profile."; return 1
  fi
  parent="${parent/#\~/$HOME}"
  local sub="${parent}-${name}"
  if [ -e "$sub" ]; then
    print -r -- "pp: sub-profile dir already exists: $sub (pick another name or remove it)."; return 1
  fi

  print -r -- "Capturing a full file-based login '$name' for profile '$prof'."
  print -r -- "  new config dir: $sub"
  print -r -- ""
  print -r -- "Step 1/3 — sign in. A browser opens; log in as the account to add"
  print -r -- "(use a private/incognito window so you don't reuse another login)."
  print -r -- "⚠ The login lands in the shared macOS Keychain slot, REPLACING whatever"
  print -r -- "  full login currently sits there. Captured (file-based) logins are"
  print -r -- "  unaffected, but a Keychain-only login would be displaced — capture"
  print -r -- "  it first if you still need it."
  local ans; read "ans?Proceed? [y/N] "
  case "$ans" in y|Y|yes|YES) ;; *) print -r -- "aborted"; return 1 ;; esac

  mkdir -p "$sub" && chmod 700 "$sub"
  _pp_inherit_config "$parent" "$sub"
  if ! CLAUDE_CONFIG_DIR="$sub" command claude auth login; then
    print -r -- "pp: login failed or aborted — nothing captured, no account added."
    return 1
  fi

  print -r -- ""
  print -r -- "Step 2/3 — extract the Keychain credential into $sub."
  print -r -- ">>> macOS will prompt — click 'Always Allow' and enter your login password."
  security find-generic-password -w -s "Claude Code-credentials" > "$sub/.credentials.json"
  chmod 600 "$sub/.credentials.json"
  if ! grep -q '"claudeAiOauth"' "$sub/.credentials.json" 2>/dev/null; then
    print -r -- "pp: extraction didn't yield a valid credential."
    print -r -- "  If the Keychain item name differs, find it in Keychain Access.app (search 'Claude')."
    rm -f "$sub/.credentials.json"
    return 1
  fi

  print -r -- ""
  print -r -- "Step 3/3 — verify + register."
  print -r -- "  $sub is now a self-contained file-based login:"
  CLAUDE_CONFIG_DIR="$sub" command claude auth status 2>/dev/null | sed 's/^/    /'
  print -r -- "  ^ make sure the email above is the account you meant to capture."
  _pp_ensure_dir "$prof"
  print -r -- "$sub" > "$(_pp_login_marker "$prof" "$name")"
  chmod 600 "$(_pp_login_marker "$prof" "$name")"
  print -r -- "✓ captured login '$name' for '$prof' (full scope, parallel-safe)"
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
  # Per-account health: each profile's native dir + every login/token account.
  # Read-only — runs `auth status`, never logs in.
  print -r -- ""
  print -r -- "  accounts (auth / creds / symlinks):"
  local cfg acct lf tf adir kind
  for name in $PP_ORDER; do
    cfg="${PP_CFG_DIR[$name]}"; cfg="${cfg/#\~/$HOME}"
    _pp_doctor_acct "$name/native" "$cfg" native
    for acct in $(_pp_list "$name"); do
      [ "$acct" = native ] && continue
      lf="$(_pp_login_marker "$name" "$acct")"; tf="$(_pp_token_file "$name" "$acct")"
      if [ -r "$lf" ]; then _pp_doctor_acct "$name/$acct" "$(command cat "$lf")" login
      elif [ -r "$tf" ]; then _pp_doctor_acct "$name/$acct" "$cfg" token; fi
    done
  done
}

# One health line for a config dir: auth state, credential location, and any
# symlinks whose target no longer resolves.
_pp_doctor_acct() {
  setopt localoptions extendedglob
  local label="$1" dir="$2" kind="$3"
  if [ "$kind" = token ]; then printf '    %-20s token account (inference-only)\n' "$label"; return; fi
  if [ ! -d "$dir" ]; then printf '    %-20s %s  ✗ dir MISSING\n' "$label" "${dir/#$HOME/~}"; return; fi
  local logged creds l broken=0 total=0 mark
  logged=$(CLAUDE_CONFIG_DIR="$dir" command claude auth status 2>/dev/null | _pp_json loggedIn)
  if [ -f "$dir/.credentials.json" ]; then creds="creds:file"; else creds="creds:keychain"; fi
  for l in "$dir"/*(@N) "$dir"/.*(@N); do total=$((total+1)); [ -e "$l" ] || broken=$((broken+1)); done
  [ "$logged" = True ] && mark="✓ auth" || mark="✗ NOT logged in"
  printf '    %-20s %s  %s  links:%s\n' "$label" "$mark" "$creds" "$([ $broken -eq 0 ] && print ok || print "$broken/$total BROKEN")"
}

# Tiny JSON field extractor (python3 if present, else a grep fallback).
_pp_json() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys
try: print(json.load(sys.stdin).get('$1'))
except Exception: print('')"
  else
    grep -o "\"$1\"[: ]*[^,}]*" | head -1 | sed 's/.*[: ]//; s/[" ]//g'
  fi
}

_pp_help() {
  cat <<'EOF'
proton-pack — Claude Code profile + account switching, by directory

  claude [args]      launch Claude in the profile + account for this directory
  pp profiles        list configured profiles (the one for this dir marked *)
  pp where           show profile + account for the current directory
  pp ls              list accounts for the current profile (with their type)
  pp add <name>      add a token account (inference-only; opens a browser login)
  pp add-login <name>  add a login sub-profile (full scope; Linux/Windows)
  pp capture <name>  add a full file-based login via Keychain extraction (macOS)
  pp use <name>      switch the active account
  pp flip            rotate to the next account (no launch); then `claude --resume`
  pp rm <name>       remove a stored account (a sub-profile's dir is left intact)
  pp run [args]      launch (same as `claude`; use when the wrapper is disabled)
  pp reload          re-read profiles.conf after editing it
  pp doctor          check config, perms, deps, and per-account health
                     (auth state, credential location, broken symlinks)
  pp help            this help

Accounts: 'native' is each profile's built-in login; stack more as b, c, d ...
  - token account (pp add): cheap, shares native's sessions, INFERENCE-ONLY.
  - login sub-profile (pp add-login): own config dir + login, FULL SCOPE
    (Remote Control, MCP auth), separate session history. Linux/Windows.
  - captured login (pp capture): same result on macOS — the login is
    extracted from the shared Keychain into the sub-profile's own file.
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
    add-login|addlogin) _pp_add_login "$prof" "$1" ;;
    capture)           _pp_capture "$prof" "$1" ;;
    use)               _pp_use "$prof" "$1" ;;
    flip|rotate)       _pp_flip "$prof" ;;
    rm|remove)         _pp_remove "$prof" "$1" ;;
    run)               _pp_launch "$@" ;;
    reload)            _pp_load && print -r -- "reloaded ${#PP_ORDER} profiles from $PP_PROFILES_FILE" ;;
    doctor)            _pp_doctor ;;
    *) print -r -- "pp: unknown command '$cmd' (try: pp help)"; return 1 ;;
  esac
}
