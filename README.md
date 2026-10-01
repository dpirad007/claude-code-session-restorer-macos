# restore-claude-code-tab-sessions-macOS

A macOS script that brings your Claude Code sessions back into the Claude Desktop **Code** tab after you switch accounts, for example from a personal Pro plan to a Team plan.

It also adds sessions you started from the CLI or VS Code, which never showed up in the Desktop app.

> Unofficial community port of [sahol3/claude-code-session-restorer](https://github.com/sahol3/claude-code-session-restorer) (MIT). Anthropic didn't make it and doesn't endorse it. The card format was worked out by watching what the app does, so an app update could break it. Use at your own risk.

## Why sessions disappear

Claude Code keeps your conversations in two places:

| What                                            | Where                                                                                        | Tied to an account? |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------- | ------------------- |
| **Transcripts** (the actual chat history)       | `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`                                         | No                  |
| **Session cards** (the list the Code tab shows) | `~/Library/Application Support/Claude/claude-code-sessions/<accountId>/<orgId>/local_*.json` | Yes                 |

Each card points to its transcript through a `cliSessionId` field. When you sign in with a different account or organization, the Desktop app reads cards from a new folder, which starts out empty. Your transcripts are still on disk, but the Code tab has no cards for them, so nothing shows up.

## What the script does

You can run it more than once safely, you can undo it, and it never changes or deletes your transcripts.

1. **Backs up** the whole `claude-code-sessions` folder to `claude-code-sessions_backup_<timestamp>`.
2. **Copies cards** from your other account and org folders (such as the old personal plan) into the target folder (such as the new Team account). Cards that are already there are skipped.
3. **Creates cards** for transcripts that don't have one anywhere, usually CLI or VS Code sessions. It reads each transcript to fill in the title, working directory, model and timestamps. Pass `--existing-only` to skip this step.

To decide which folder to write to, it checks the account you're signed in with in `~/.claude.json` and suggests that one. You can also pick a folder from a list or give one with `--dest`.

## Requirements

- macOS
- `python3`. If you don't have it, install Apple's Command Line Tools: `xcode-select --install`
- Claude Desktop **fully quit** (Cmd+Q). The app rewrites the card folder when it exits, which would overwrite the script's changes, so the script won't run while the app is open.

## Usage

1. Open Claude Desktop with your **new** account and start at least one Code session, so the app creates the new account's folder. Then quit with **Cmd+Q**.
2. Preview the changes. This writes nothing:

   ```bash
   ./restore-code-tab-sessions.sh --dry-run
   ```

3. Run it for real:

   ```bash
   ./restore-code-tab-sessions.sh
   ```

   When asked, pick the folder for the account you're switching **to** (the Team account). The one marked `<- current Claude Code login` is usually right.

4. Reopen Claude Desktop and go to the **Code** tab. Your sessions should be listed.

### Options

| Flag               | Description                                                                                                 |
| ------------------ | ----------------------------------------------------------------------------------------------------------- |
| `--dry-run`        | Show what would happen without changing anything.                                                           |
| `--existing-only`  | Only copy cards that were made in the Desktop Code tab under other accounts. Skip CLI and VS Code sessions. |
| `--dest <path>`    | Write cards to this folder instead of choosing one.                                                         |
| `--list`           | List every account/org card folder with its card count, then exit.                                          |
| `-y`, `--yes`      | Don't ask which folder to use. Go with the one the script detects.                                          |
| `--no-backup`      | Skip the backup (not recommended).                                                                          |
| `--ignore-running` | Run even if the script thinks Claude Desktop is open.                                                       |
| `-h`, `--help`     | Show help.                                                                                                  |

To point the script at a different card folder (for example, when testing), set the `CLAUDE_SESSIONS_DIR` environment variable.

## Undo

1. Quit Claude Desktop (Cmd+Q).
2. In `~/Library/Application Support/Claude/`, delete or rename the `claude-code-sessions` folder.
3. Rename the `claude-code-sessions_backup_<timestamp>` folder that the script printed to `claude-code-sessions`.

## License

[MIT](LICENSE). This includes the copyright notice from the original [sahol3/claude-code-session-restorer](https://github.com/sahol3/claude-code-session-restorer), as its MIT license requires.
