#!/usr/bin/env zsh
# proton-pack self-test. Runs in an isolated temp config; never launches claude
# and never touches your real profiles or tokens.
#   zsh test/test.zsh
emulate -L zsh
ROOT="$(mktemp -d)"
export PP_CONFIG_DIR="$ROOT/cfg"
export PP_PROFILES_FILE="$PP_CONFIG_DIR/profiles.conf"
export PP_ACCOUNTS_DIR="$PP_CONFIG_DIR/accounts"
export PP_NO_WRAP=1            # don't override `claude` in the test shell
mkdir -p "$PP_CONFIG_DIR" "$ROOT/work/sub" "$ROOT/home"
cat > "$PP_PROFILES_FILE" <<EOF
work     | $ROOT/.claude-work     | Jane Doe | jane@corp.com  | - | $ROOT/work $ROOT/work/*
personal | $ROOT/.claude-personal | janedev  | jane@gmail.com | - | default
EOF

source "${0:A:h}/../proton-pack.zsh"

pass=0 fail=0
ok()  { print -r -- "  ok:   $1"; pass=$((pass+1)); }
bad() { print -r -- "  FAIL: $1"; fail=$((fail+1)); }
perm() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }

print -r -- "1) routing by directory"
( cd "$ROOT/work"     && [ "$(_pp_profile_for_pwd)" = work ] )     && ok "work dir -> work"          || bad "work dir routing"
( cd "$ROOT/work/sub" && [ "$(_pp_profile_for_pwd)" = work ] )     && ok "work subdir -> work"       || bad "work subdir routing"
( cd "$ROOT/home"     && [ "$(_pp_profile_for_pwd)" = personal ] ) && ok "elsewhere -> default"      || bad "default routing"

print -r -- "2) account-name validation"
for n in b max2 a.b a_b a-b; do _pp_valid_name "$n" && ok "accept '$n'" || bad "should accept '$n'"; done
for n in '' native . .. '../x' 'a/b' 'a b' '-x'; do _pp_valid_name "$n" && bad "should reject '$n'" || ok "reject '$n'"; done

print -r -- "3) add refuses unsafe names; nothing escapes the store"
_pp_add_account work '../../evil' >/dev/null 2>&1
[ $? -ne 0 ] && ok "add '../../evil' refused" || bad "add '../../evil' not refused"
{ [ ! -e "$ROOT/cfg/evil.token" ] && [ ! -e "$ROOT/evil.token" ]; } && ok "no file escaped the store" || bad "FILE ESCAPED"

print -r -- "4) store dir 0700, token file 0600"
_pp_ensure_dir work
[ "$(perm "$PP_ACCOUNTS_DIR/work")" = 700 ] && ok "work dir is 0700" || bad "work dir is $(perm "$PP_ACCOUNTS_DIR/work")"
( umask 077; print -r -- "sk-ant-oat01-FAKE-SECRET-XYZ" > "$PP_ACCOUNTS_DIR/work/b.token" ); chmod 600 "$PP_ACCOUNTS_DIR/work/b.token"
[ "$(perm "$PP_ACCOUNTS_DIR/work/b.token")" = 600 ] && ok "b.token is 0600" || bad "b.token is $(perm "$PP_ACCOUNTS_DIR/work/b.token")"

print -r -- "5) token never shown by ls / where"
out="$( cd "$ROOT/work" && { pp ls; pp where; } 2>&1 )"
print -r -- "$out" | grep -q 'FAKE-SECRET' && bad "TOKEN LEAKED to ls/where" || ok "token absent from ls/where"

print -r -- "6) injected token does not persist in the shell"
_demo() { local -x CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-LEAKCHECK"; : ; }; _demo
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && ok "env var unset after return" || bad "env var PERSISTED"

print -r -- "7) flip rotates, no launch"
out="$( cd "$ROOT/work" && pp flip 2>&1 )"
print -r -- "$out" | grep -q 'native → b' && ok "flip native → b" || bad "flip did not report native → b"
out="$( cd "$ROOT/work" && pp flip 2>&1 )"
print -r -- "$out" | grep -q 'b → native' && ok "flip b → native" || bad "flip did not rotate back"

print -r -- "8) login sub-profile: inherits config, NEVER credentials"
PARENT="$ROOT/.claude-work"; mkdir -p "$PARENT"
print -r -- '{"theme":"dark"}' > "$PARENT/settings.json"
print -r -- '{"mcpServers":{"slack":{"url":"https://mcp.slack.com/mcp"}},"oauthAccount":{"x":1},"userID":"SECRETUID"}' > "$PARENT/.claude.json"
print -r -- 'TOPSECRET-CRED' > "$PARENT/.credentials.json"
( cd "$ROOT/work" && pp add-login c ) >/dev/null 2>&1
SUB="$ROOT/.claude-work-c"
[ -d "$SUB" ] && ok "sub-profile dir created" || bad "sub-profile dir missing"
[ -f "$SUB/settings.json" ] && ok "settings inherited" || bad "settings not inherited"
grep -q '"slack"' "$SUB/.claude.json" 2>/dev/null && ok "mcpServers inherited" || bad "mcpServers not inherited"
[ ! -f "$SUB/.credentials.json" ] && ok "credentials NOT copied" || bad "CREDENTIALS COPIED"
grep -qE 'oauthAccount|SECRETUID' "$SUB/.claude.json" 2>/dev/null && bad "account metadata LEAKED" || ok "no account metadata in sub .claude.json"
[ "$(_pp_acct_type work c)" = login ] && ok "type reported as login" || bad "type not login"
[ "$(perm "$PP_ACCOUNTS_DIR/work/c.login")" = 600 ] && ok "login marker is 0600" || bad "login marker is $(perm "$PP_ACCOUNTS_DIR/work/c.login")"
[ "$(perm "$SUB")" = 700 ] && ok "sub-profile dir is 0700" || bad "sub-profile dir is $(perm "$SUB")"
( cd "$ROOT/work" && _pp_list work ) | grep -qx c && ok "list includes login account c" || bad "list missing login account c"
out="$( cd "$ROOT/work" && pp add-login c 2>&1 )"; print -r -- "$out" | grep -q 'already exists' && ok "duplicate add-login refused" || bad "duplicate add-login NOT refused"
out="$( cd "$ROOT/work" && pp use c 2>&1 )"; print -r -- "$out" | grep -q '(login)' && ok "use reports login type" || bad "use did not report login type"
# rm removes the marker but leaves the sub-profile dir intact
out="$( cd "$ROOT/work" && pp rm c 2>&1 )"
[ ! -e "$PP_ACCOUNTS_DIR/work/c.login" ] && ok "rm removed the login marker" || bad "marker not removed"
[ -d "$SUB" ] && ok "rm left sub-profile dir intact" || bad "rm deleted the sub-profile dir"
print -r -- "$out" | grep -q 'reset to native' && ok "rm reset active to native" || bad "rm did not reset active"

print -r -- ""
print -r -- "passed: $pass   failed: $fail"
rm -rf "$ROOT"
if [ $fail -eq 0 ]; then print -r -- "ALL TESTS PASSED"; else print -r -- "SOME TESTS FAILED"; fi
[ $fail -eq 0 ]
