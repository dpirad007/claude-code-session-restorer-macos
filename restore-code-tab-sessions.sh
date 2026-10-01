#!/usr/bin/env bash
# =============================================================================
# restore-code-tab-sessions.sh  (macOS)
# -----------------------------------------------------------------------------
# Make your Claude Code sessions show up again in the Claude Desktop "Code" tab
# after switching accounts (e.g. Pro -> Team), or for sessions started from the
# CLI / VS Code that never appeared in the app.
#
# WHY SESSIONS GO MISSING
#   Transcripts live in ~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl and
#   carry no account info. But the Code tab only lists small per-session "card"
#   files stored per account + organization:
#     ~/Library/Application Support/Claude/claude-code-sessions/<accountId>/<orgId>/local_*.json
#   Each card links to a transcript via "cliSessionId". Switch accounts and the
#   app looks in a different (empty) folder.
#
# WHAT THIS DOES (idempotent, reversible, never touches your transcripts)
#   1. Backs up the whole card index.
#   2. Copies cards from OTHER account/org folders into the target folder.
#   3. (default) Creates cards for transcripts that have none anywhere
#      (CLI / VS Code sessions), using each session's real title.
#
# USAGE
#   1. Quit Claude Desktop completely (Cmd+Q).
#   2. chmod +x restore-code-tab-sessions.sh
#      ./restore-code-tab-sessions.sh --dry-run     # preview, writes nothing
#      ./restore-code-tab-sessions.sh               # do it
#   3. Reopen Claude Desktop -> Code tab.
#
# OPTIONS
#   --dry-run          Show what would happen; change nothing.
#   --existing-only    Only move cards created in the Desktop Code tab under
#                      other accounts. Skip CLI / VS Code sessions.
#   --dest <path>      Write cards to this folder instead of choosing one.
#   --list             List the account/org card folders and exit.
#   -y, --yes          Don't prompt; use the auto-detected target folder.
#   --no-backup        Skip the index backup (not recommended).
#   --ignore-running   Don't abort if Claude Desktop is running.
#
# UNDO
#   Quit Claude Desktop, then replace the claude-code-sessions folder with the
#   claude-code-sessions_backup_<timestamp> folder this script printed.
#
# Unofficial community port of sahol3/claude-code-session-restorer (MIT).
# Not affiliated with or endorsed by Anthropic. The card format was worked out
# by observation and may change with app updates. Use at your own risk.
# =============================================================================
set -euo pipefail

IGNORE_RUNNING=0
for a in "$@"; do
  case "$a" in
    --ignore-running) IGNORE_RUNNING=1 ;;
    -h|--help) sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" && -z "${CLAUDE_SESSIONS_DIR:-}" ]]; then
  echo "This script is for macOS (set CLAUDE_SESSIONS_DIR to override)." >&2
  exit 1
fi

# Claude Desktop rewrites the card folder when it exits, so it must be closed.
if [[ $IGNORE_RUNNING -eq 0 ]] && pgrep -x "Claude" >/dev/null 2>&1; then
  echo "Claude Desktop is still running. Quit it completely (Cmd+Q), then re-run." >&2
  echo "(Or pass --ignore-running if you're sure it isn't.)" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import json' >/dev/null 2>&1; then
  echo "python3 is required. Install Apple's Command Line Tools with:  xcode-select --install" >&2
  exit 1
fi

read -r -d '' PY_SRC <<'PYEOF' || true
import argparse, datetime, json, os, shutil, sys, uuid
from pathlib import Path

ap = argparse.ArgumentParser(add_help=False)
ap.add_argument("--dry-run", action="store_true")
ap.add_argument("--existing-only", action="store_true")
ap.add_argument("--dest")
ap.add_argument("--list", action="store_true")
ap.add_argument("-y", "--yes", action="store_true")
ap.add_argument("--no-backup", action="store_true")
ap.add_argument("--ignore-running", action="store_true")
args, unknown = ap.parse_known_args(sys.argv[1:])
if unknown:
    sys.exit("Unknown option(s): %s  (see --help)" % " ".join(unknown))

HOME = Path.home()
PROJ_ROOT = HOME / ".claude" / "projects"
APP_BASE = Path(os.environ.get("CLAUDE_SESSIONS_DIR") or
                HOME / "Library" / "Application Support" / "Claude" / "claude-code-sessions")
C = sys.stdout.isatty()
def say(msg, color=None):
    codes = {"cyan": "36", "green": "32", "yellow": "33", "bold": "1"}
    print(f"\033[{codes[color]}m{msg}\033[0m" if C and color else msg)

def read_json(p):
    try:
        with open(p, encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return None

def card_folders():
    out = []
    if APP_BASE.is_dir():
        for acct in sorted(APP_BASE.iterdir()):
            if not acct.is_dir():
                continue
            for org in sorted(acct.iterdir()):
                if org.is_dir():
                    cards = list(org.glob("local_*.json"))
                    mtime = max([c.stat().st_mtime for c in cards] + [org.stat().st_mtime])
                    out.append((org, len(cards), mtime))
    return out

def fmt_time(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")

say("== Claude Code -> Code-tab session restorer (macOS) ==", "bold")
if args.dry_run:
    say("DRY RUN: nothing will be written.", "yellow")

folders = card_folders()

if args.list:
    if not folders:
        say(f"No card folders found under {APP_BASE}")
    for org, n, mt in folders:
        print(f"  {n:4d} cards  last change {fmt_time(mt)}  {org.parent.name}/{org.name}")
    sys.exit(0)

# --- Work out the logged-in account from the Claude Code CLI config ----------
cli_dest, cli_label = None, ""
cj = read_json(HOME / ".claude.json")
oa = (cj or {}).get("oauthAccount") or {}
if oa.get("accountUuid") and oa.get("organizationUuid"):
    cli_dest = APP_BASE / oa["accountUuid"] / oa["organizationUuid"]
    who = oa.get("emailAddress") or oa["accountUuid"]
    org_name = oa.get("organizationName") or oa["organizationUuid"]
    cli_label = f"{who} / {org_name}"

# --- Choose the target folder -----------------------------------------------
if args.dest:
    dest = Path(args.dest).expanduser()
else:
    choices = [(org, f"{n} cards, last change {fmt_time(mt)}") for org, n, mt in folders]
    if cli_dest and cli_dest not in [c[0] for c in choices]:
        choices.append((cli_dest, "not created yet"))
    if not choices:
        sys.exit("No Code-tab folders found and no Claude Code login in ~/.claude.json.\n"
                 "Open Claude Desktop with your new account, start one Code session, quit, and re-run.")
    if cli_dest:
        default = [c[0] for c in choices].index(cli_dest)
    else:
        default = max(range(len(folders)), key=lambda i: folders[i][2])
    say("Code-tab folders (account/organization):", "cyan")
    for i, (org, info) in enumerate(choices, 1):
        tag = ""
        if org == cli_dest:
            tag = f"  <- current Claude Code login ({cli_label})"
        print(f"  [{i}] {org.parent.name}/{org.name}  ({info}){tag}")
    if args.yes:
        dest = choices[default][0]
    else:
        print()
        print("Pick the folder for the account you're switching TO (your Team account).")
        ans = input(f"Number [default {default + 1}], or q to quit: ").strip().lower()
        if ans == "q":
            sys.exit(0)
        try:
            dest = choices[int(ans) - 1 if ans else default][0]
        except (ValueError, IndexError):
            sys.exit("Invalid choice.")

say(f"Target card folder: {dest}", "cyan")
if not args.dry_run:
    dest.mkdir(parents=True, exist_ok=True)

# --- Backup ------------------------------------------------------------------
if not args.no_backup and not args.dry_run and APP_BASE.is_dir():
    bk = APP_BASE.parent / (APP_BASE.name + "_backup_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))
    shutil.copytree(APP_BASE, bk, symlinks=True)
    say(f"Backed up Code-tab index -> {bk}", "green")

# --- Defaults cloned from an existing card ----------------------------------
tmpl = None
all_cards = sorted(APP_BASE.rglob("local_*.json"), key=lambda p: p.stat().st_size) if APP_BASE.is_dir() else []
for c in all_cards:
    tmpl = read_json(c)
    if isinstance(tmpl, dict):
        break
tmpl = tmpl if isinstance(tmpl, dict) else {}
def_model = tmpl.get("model")
def_effort = tmpl.get("effort") or "high"
def_chrome = tmpl.get("chromePermissionMode") or "default"
def_mcp = tmpl.get("remoteMcpServersConfig")

# --- What's already in the target -------------------------------------------
have = set()
if dest.is_dir():
    for f in dest.glob("local_*.json"):
        o = read_json(f)
        if isinstance(o, dict) and o.get("cliSessionId"):
            have.add(str(o["cliSessionId"]).lower())

# --- 1) Copy cards from other account/org folders ---------------------------
copied = 0
for f in all_cards:
    if f.parent.resolve() == dest.resolve() if dest.exists() else f.parent == dest:
        continue
    o = read_json(f)
    if not isinstance(o, dict) or not o.get("cliSessionId"):
        continue
    key = str(o["cliSessionId"]).lower()
    if key in have:
        continue
    have.add(key)
    copied += 1
    if args.dry_run:
        print(f"  would copy: {o.get('title') or f.name}")
        continue
    target = dest / f.name
    if target.exists():
        new_id = f"local_{uuid.uuid4()}"
        o["sessionId"] = new_id
        target.write_text(json.dumps(o, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    else:
        shutil.copy2(f, target)
say(f"{'Would copy' if args.dry_run else 'Copied'} {copied} card(s) from other account folders.", "green")

# --- 2) Generate cards for transcripts with none -----------------------------
def iso_ms(s):
    try:
        return int(datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() * 1000)
    except Exception:
        return None

def meta(path):
    cwd = created = ai = summ = usr = model = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for i, line in enumerate(fh):
            if i >= 400:
                break
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if not isinstance(o, dict):
                continue
            created = created or o.get("timestamp")
            cwd = cwd or o.get("cwd")
            t = o.get("type")
            if not ai and t == "ai-title" and o.get("aiTitle"):
                ai = o["aiTitle"]
            if not summ and t == "summary" and o.get("summary"):
                summ = o["summary"]
            msg = o.get("message") if isinstance(o.get("message"), dict) else {}
            if not model and t == "assistant" and msg.get("model") and not str(msg["model"]).startswith("<"):
                model = msg["model"]
            if not usr and t == "user" and msg:
                c = msg.get("content")
                txt = c if isinstance(c, str) else next(
                    (b.get("text") for b in (c or []) if isinstance(b, dict) and b.get("type") == "text"), None)
                if txt:
                    s = txt.strip()
                    if not (s.startswith("<") or s.startswith("This session is being continued")
                            or s.startswith("Caveat:") or s.startswith("Base directory for this skill")):
                        usr = txt
            if cwd and created and ai and model:
                break
    title = ai or summ or usr
    if title:
        title = " ".join(title.split())[:80]
    return cwd, created, title, model

generated = skipped = 0
if args.existing_only:
    say("--existing-only: skipping CLI / VS Code sessions.", "yellow")
elif PROJ_ROOT.is_dir():
    for jf in PROJ_ROOT.rglob("*.jsonl"):
        if "subagents" in jf.parts or jf.name.startswith("agent-"):
            continue
        key = jf.stem.lower()
        if key in have:
            skipped += 1
            continue
        cwd, created, title, model = meta(jf)
        st = jf.stat()
        last = int(st.st_mtime * 1000)
        born = iso_ms(created) if created else None
        if born is None:
            born = int(getattr(st, "st_birthtime", st.st_mtime) * 1000)
        if not title:
            title = f"{Path(cwd).name if cwd else 'session'} (recovered)"
        have.add(key)
        generated += 1
        if args.dry_run:
            print(f"  would create: {title}")
            continue
        gid = str(uuid.uuid4())
        rec = {
            "sessionId": f"local_{gid}", "cliSessionId": jf.stem,
            "cwd": cwd or "", "originCwd": cwd or "",
            "lastFocusedAt": last, "createdAt": born, "lastActivityAt": last,
            "model": model or def_model or "claude-opus-4-5", "effort": def_effort,
            "isArchived": False, "title": title, "titleSource": "auto",
            "permissionMode": "default", "remoteMcpServersConfig": def_mcp,
            "chromePermissionMode": def_chrome, "completedTurns": 1,
            "alwaysAllowedReasons": None, "sessionPermissionUpdates": None,
            "classifierSummaryEnabled": True,
        }
        (dest / f"local_{gid}.json").write_text(
            json.dumps(rec, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    say(f"{'Would create' if args.dry_run else 'Created'} {generated} new card(s); "
        f"{skipped} already present.", "green")

if args.dry_run:
    say("Dry run finished. Re-run without --dry-run to apply.", "bold")
else:
    total = len(list(dest.glob("local_*.json")))
    say(f"DONE. This account's Code tab now has {total} session card(s).", "bold")
    say("Open Claude Desktop -> Code tab. Your sessions should be listed.", "cyan")
PYEOF

exec python3 -c "$PY_SRC" "$@"
