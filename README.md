# proton-pack

Run multiple Claude Code accounts and orgs on one machine without crossing the
streams. `proton-pack` switches your Claude **profile** automatically based on
the directory you're in, and lets you **stack several Max plans** per profile so
you can flip to a fresh one the moment you hit a usage limit.

It's a single zsh file. No daemon, no TUI, no dependencies beyond `claude` (and
optionally `gh`).

## The two ideas

These are independent, and keeping them separate is the whole trick:

1. **Profile** — *which workspace you're in.* A profile is a `CLAUDE_CONFIG_DIR`
   plus a git identity and (optionally) a GitHub CLI account. Work and personal
   each get their own login, skills, and settings, and the right one is chosen
   from your current directory. This is the "don't cross the streams" part.
2. **Account** — *which Anthropic login provides the usage.* Each profile can
   stack several accounts. `native` is the profile's built-in login (full
   scope); stack more as `b`, `c`, `d` … When one runs out, `pp flip` switches
   to the next. Stacked accounts come in two flavors — a **token** account or a
   **login sub-profile** — but read the macOS caveat below first.

### Account types

|  | **token** (`pp add`) | **login sub-profile** (`pp add-login`) | **captured login** (`pp capture`) |
|---|---|---|---|
| How | A long-lived OAuth token (`claude setup-token`) injected at launch | Its own config dir with its own `claude auth login` | Its own config dir; the login is extracted from the macOS Keychain into a file |
| Platform | All | **Linux/Windows** (see the macOS note) | **macOS** |
| Setup | Paste a token once | Browser login once | Browser login + one Keychain prompt |
| Isolates the login | Yes — env-var token, never touches the keychain (safe to run in parallel) | Yes (per-dir credential files) | Yes (per-dir credential file) |
| Scope | **Inference-only**: no Remote Control, no cloud review (`ultra`), no claude.ai / remote-OAuth MCP servers | Full (it's a real login) | Full (it's a real login) |
| Best for | Quick failover coding through a usage limit | A second full-scope account on Linux/Windows | A second full-scope account on macOS |

> ### macOS note — the shared Keychain slot, and how `pp capture` gets around it
> On macOS, `claude auth login` always writes the subscription login to one
> **shared Keychain slot** — never a per-dir file, even into a pre-seeded config
> dir. So plain `pp add-login` can't isolate a second login there. But a config
> dir that holds its **own credential file** is a complete full-scope login that
> ignores the Keychain entirely — and the Keychain item can be extracted into
> exactly that file. That's what **`pp capture`** does: sign in (lands in the
> Keychain), then extract the item into the sub-profile's `.credentials.json`.
> The result has everything a native login has — Remote Control, claude.ai MCP
> servers, cloud review — and runs in parallel with your other logins.
>
> Two cautions: each `claude auth login` **replaces** whatever is in the shared
> slot, so never log in over an account you haven't captured to a file. And the
> captured credential is a **plaintext 0600 file** — an explicit tradeoff; see
> Security. Reversible: delete the dir's `.credentials.json` and that dir falls
> back to the Keychain.

> **Heads-up (all platforms):** Remote Control, cloud review, and claude.ai /
> remote-OAuth MCP servers all require a *full* login — a token account can't use
> them. `pp ls` shows each account's type so you know which you're on.

## Install

```sh
git clone https://github.com/<you>/proton-pack.git ~/code/proton-pack
~/code/proton-pack/install.sh
```

The installer creates `~/.config/proton-pack/`, drops in an example config, and
adds one `source` line to your `~/.zshrc`. It never overwrites existing config.
Open a new terminal afterward (or `source ~/code/proton-pack/proton-pack.zsh`).

## Configure

Edit `~/.config/proton-pack/profiles.conf`. One profile per line:

```
# name | config_dir | git_name | git_email | gh_user | match
work     | ~/.claude-work     | Jane Doe | jane@corp.com  | jane-corp | ~/code/work/* */work */work/*
personal | ~/.claude-personal | janedev  | jane@gmail.com | janedev   | default
```

- `match` is space-separated path globs, or `default` for the fallback.
- Profiles are tried top to bottom; the first glob that matches your current
  directory wins, so put more specific profiles first.
- Any of `git_name`, `git_email`, `gh_user` can be `-` to leave them alone.

Run `pp doctor` to sanity-check your config, then `pp profiles` to see what
matches where. Each profile's `config_dir` is created and logged into the first
time you launch `claude` there.

## Use

```sh
claude                 # launches in the profile + account for your current dir
pp where               # what will `claude` use here?
pp ls                  # accounts for this profile + their type (active one *)
pp add b               # stack a token account (inference-only; browser login)
pp add-login b         # stack a login sub-profile (full scope; Linux/Windows)
pp capture b           # stack a full file-based login via Keychain extraction (macOS)
pp use b               # switch the active account
pp flip                # rotate to the next account, then run `claude --resume`
pp rm b                # remove a stored account
```

`pp add` opens a browser login in a throwaway config dir, so your existing
logins are never touched. Sign in as the account you want to stack — **use a
private/incognito window** so you don't accidentally mint a token for an account
you're already signed into.

`pp add-login` (**Linux/Windows** — see the macOS caveat above) makes a sibling
config dir (`<profile-dir>-<name>`) that inherits the profile's settings and MCP
servers — but never its credentials — then prints the one command to log it in:

```sh
pp add-login b                                      # in a work directory
CLAUDE_CONFIG_DIR=~/.claude-work-b command claude auth login   # log in the 2nd account
CLAUDE_CONFIG_DIR=~/.claude-work-b command claude auth status  # confirm it's different
pp use b                                            # activate it (full scope)
```

Both `pp add-login` and `pp capture` make the sub-profile **inherit the parent
profile's personality** so it behaves identically — only the login differs. They
copy `settings`, MCP-server config, and a per-profile `CLAUDE.md`, and they
**replicate every symlink the parent profile has** (this is how a profile shares
one canonical set of commands, skills, plugins, and agents across its accounts —
if your profile dir symlinks `skills`/`commands`/`plugins` to a shared location,
the sub-profile gets the same links). Credentials, account identity, and session
history are never copied.

A login sub-profile's session history is separate from `native` (it's a
different config dir), and its inherited MCP/settings are a snapshot taken at
creation. `pp rm` removes it from the account list but leaves the config dir on
disk (it's a real login) — delete it yourself when you're done with it. On macOS
this won't isolate the login (shared Keychain) — use `pp capture` instead.

`pp capture` (**macOS** — see the macOS note above) is the same idea with one
extra step: it creates the sub-profile dir, opens `claude auth login` (sign in
as the account to add — **incognito window**), then extracts the resulting
Keychain credential into the dir's own `.credentials.json` (macOS prompts once —
"Always Allow"). It verifies by printing the captured account's `auth status`
so you can confirm the email before the account is registered:

```sh
pp capture b           # in a work directory: confirm -> browser login -> Keychain prompt
pp use b               # activate it (full scope), or: pp flip
```

It refuses to overwrite anything that exists — existing account names, existing
sub-profile dirs — and a failed or aborted login adds nothing.

### Hitting a usage limit

The limit is per-account, so every session on that account pauses at once. You
don't have to quit them — open a new terminal and:

```sh
pp flip                # switch this profile to the next account (no launch)
claude --resume        # reopen the session you want, now on the new account
```

The switch applies to the whole profile, so once you've flipped, every session
you resume runs on the new account. Close the old paused windows so the same
conversation isn't open in two places.

## Security

- Token files are `0600` and the store directories are `0700`.
- The active token is passed to Claude as an environment variable scoped to a
  single launch — it's unset on return, never persists in your shell, and never
  appears in any process's argument list. As with any env-var secret, other
  processes running as *you* can read a running process's environment; that's
  inherent to the mechanism.
- `claude setup-token` prints the token to your terminal when you add an
  account, so it lands in scrollback. Run `clear` (and clear any tmux/terminal
  logging) afterward.
- Account names are validated (letters, digits, `.`, `_`, `-`) to prevent path
  tricks; `native` is reserved.
- To revoke an account: remove the token in the Anthropic console, then
  `pp rm <name>`. Tokens are long-lived (~1 year), so revoke promptly if one is
  exposed.
- **Login sub-profiles never copy credentials.** `pp add-login` inherits only
  settings and MCP-server config from the parent; the login itself is created by
  `claude auth login` and stored by Claude (a per-dir file or your OS keychain),
  exactly like any other profile's native login.
- **Captured logins are plaintext, full-scope credentials on disk** (`0600`
  file, `0700` dir). That's the deliberate tradeoff `pp capture` makes to get a
  second full login on macOS: convenience and parallelism in exchange for a
  credential file any process running as you can read. Treat the dir like a
  private key: don't commit, sync, or back it up anywhere you wouldn't put an
  SSH key. To revoke, sign that account out from the Anthropic console (or log
  it in again elsewhere — extraction doesn't survive rotation forever) and
  delete the dir. To undo just the file mechanism, delete the dir's
  `.credentials.json` — the dir falls back to the Keychain.
- A Claude Code update could change the credential format or storage and break
  captured logins; if that happens, re-run `pp capture`.

Run `zsh test/test.zsh` for a self-check that asserts the above, and
`zsh test/integration.zsh` to verify the launch path injects the right config
and token end to end (against a fake `claude`, so no account is needed).

## Notes

- `proton-pack` overrides the `claude` command so it can route by directory.
  It always falls through to the real binary, and you can disable the override
  with `PP_NO_WRAP=1` before sourcing (then launch via `pp run`).
- Multiple accounts per person is convenient for separating work and personal
  orgs. Check your plan's terms before relying on stacked accounts purely to
  extend a single person's usage limits.
- zsh only.
