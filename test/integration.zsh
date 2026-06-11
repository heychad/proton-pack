#!/usr/bin/env zsh
# Integration test: drives the real `claude` wrapper against a FAKE claude
# binary that records the environment + args it was launched with. Proves
# proton-pack injects the right CLAUDE_CONFIG_DIR, git identity, and account
# token end to end. No real Anthropic account or network needed.
#   zsh test/integration.zsh
emulate -L zsh
# Simulate a clean login shell: drop anything inherited from the parent that
# would otherwise short-circuit routing (a preset CLAUDE_CONFIG_DIR is honored
# by design, so we must clear it here to exercise directory routing).
unset CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
ROOT="$(mktemp -d)"
mkdir -p "$ROOT/bin" "$ROOT/work/repo" "$ROOT/home"

cat > "$ROOT/bin/claude" <<'STUB'
#!/usr/bin/env bash
{
  echo "args=$*"
  echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-}"
  echo "GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-}"
  echo "HAS_TOKEN=$([ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo yes || echo no)"
  echo "TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}"
} > "${PP_TEST_REPORT:-/dev/stdout}"
STUB
chmod +x "$ROOT/bin/claude"
export PATH="$ROOT/bin:$PATH"
export PP_TEST_REPORT="$ROOT/report"

export PP_CONFIG_DIR="$ROOT/cfg" PP_PROFILES_FILE="$ROOT/cfg/profiles.conf" PP_ACCOUNTS_DIR="$ROOT/cfg/accounts"
mkdir -p "$PP_CONFIG_DIR"
cat > "$PP_PROFILES_FILE" <<EOF
work     | $ROOT/.claude-work     | Jane Doe | jane@corp.com  | - | $ROOT/work $ROOT/work/*
personal | $ROOT/.claude-personal | janedev  | jane@gmail.com | - | default
EOF

source "${0:A:h}/../proton-pack.zsh"   # defines the claude() wrapper

pass=0 fail=0
ok(){  print -r -- "  ok:   $1"; pass=$((pass+1)); }
bad(){ print -r -- "  FAIL: $1"; fail=$((fail+1)); }
field(){ grep -E "^$1=" "$PP_TEST_REPORT" | head -1 | cut -d= -f2-; }

print -r -- "A) native launch in a work directory"
( cd "$ROOT/work/repo" && claude --resume )
[ "$(field CLAUDE_CONFIG_DIR)" = "$ROOT/.claude-work" ] && ok "config dir = work" || bad "config dir = $(field CLAUDE_CONFIG_DIR)"
[ "$(field GIT_AUTHOR_EMAIL)" = "jane@corp.com" ]       && ok "git identity = work" || bad "git email = $(field GIT_AUTHOR_EMAIL)"
[ "$(field args)" = "--resume" ]                        && ok "args passed through" || bad "args = $(field args)"
[ "$(field HAS_TOKEN)" = "no" ]                         && ok "native injects no token" || bad "native leaked a token"

print -r -- "B) stacked account injects its token"
mkdir -p "$PP_ACCOUNTS_DIR/work"
( umask 077; print -r -- "sk-ant-oat01-WORKB" > "$PP_ACCOUNTS_DIR/work/b.token" )
print -r -- b > "$PP_ACCOUNTS_DIR/work/.active"
( cd "$ROOT/work/repo" && claude )
[ "$(field HAS_TOKEN)" = "yes" ]                  && ok "token present under account b" || bad "token missing"
[ "$(field TOKEN)" = "sk-ant-oat01-WORKB" ]       && ok "correct token value injected"  || bad "wrong token"
[ "$(field CLAUDE_CONFIG_DIR)" = "$ROOT/.claude-work" ] && ok "config dir still work" || bad "config dir changed"

print -r -- "C) token does not persist in the shell after launch"
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && ok "no token in shell env" || bad "token leaked to shell"

print -r -- "D) default routing falls through to personal"
( cd "$ROOT/home" && claude )
[ "$(field CLAUDE_CONFIG_DIR)" = "$ROOT/.claude-personal" ] && ok "elsewhere -> personal" || bad "default routing"

print -r -- "E) a preset CLAUDE_CONFIG_DIR bypasses routing"
( cd "$ROOT/work/repo" && CLAUDE_CONFIG_DIR=/tmp/preset claude )
[ "$(field CLAUDE_CONFIG_DIR)" = "/tmp/preset" ] && ok "preset respected (no override)" || bad "preset bypass"

print -r -- ""
print -r -- "passed: $pass   failed: $fail"
rm -rf "$ROOT"
if [ $fail -eq 0 ]; then print -r -- "INTEGRATION OK"; else print -r -- "INTEGRATION FAILED"; fi
[ $fail -eq 0 ]
