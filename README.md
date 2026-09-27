# tmux-glacier

It is a hard fork of [clanghans/tmux-frost](https://github.com/clanghans/tmux-frost) with bug fixes and macOS compatibility improvements.

Freeze your tmux sessions, thaw them later. No status-bar hijacking, one plugin instead of two.

## Why

I've been using tmux daily for over five years and was pretty happy with tmux-resurrect and tmux-continuum for most of that time. But a few things always bugged me:

1. **continuum hijacks `status-right`** — my theme would constantly overwrite it, breaking auto-save or vice versa.
2. **resurrect's stacked-pane bug** — restored layouts often leave panes with a height of 1, and the project has been effectively unmaintained for a while now.
3. **Two plugins for one job** — needing both resurrect *and* continuum just to save and restore sessions felt like unnecessary complexity.
4. **Too many features I don't use** — process restoration, strategy hooks, and other extras add weight I never needed. I just want my windows, panes, and layouts back.

tmux-glacier is a single plugin that does save, restore, and auto-save/restore with none of the baggage.

## Features

- **Save & restore** all sessions, windows, panes, and layouts
- **Auto-restore** on server start — previous layout restored automatically
- **Auto-save** at a configurable interval (default: 15 min)
- **Stacked-pane fix** — detects broken layouts at save time and replaces them with `tiled`
- **Dedup** — identical saves don't create new files
- **Backup retention** — old saves cleaned up automatically (default: 30 days, keeps newest 5)
- **Locking** — `flock`-based mutual exclusion prevents concurrent freeze/thaw

## Requirements

- tmux 3.0+
- bash
- [TPM](https://github.com/tmux-plugins/tpm)

## Install

Add to `~/.tmux.conf`:

```tmux
set -g @plugin 'shipitlater/tmux-glacier'
```

Then reload tmux and press `prefix + I` to install. TPM loads the plugin via the `glacier.tmux` entrypoint.

To pin to a specific release (recommended for stability):

```tmux
set -g @plugin 'shipitlater/tmux-glacier#v1.1'
```

TPM passes the tag to `git clone -b`, so this works for any release tag. Pinned installs won't update when you press `prefix + U` — to upgrade, change the tag and reinstall.

## Keybindings

| Binding | Action |
|---|---|
| `prefix + C-s` | Save (freeze) all sessions |
| `prefix + C-r` | Restore (thaw) from last save |

## What gets saved

- All sessions, windows, and panes
- Window layouts and names
- Pane working directories and titles
- Active window/pane selections
- Client session state
- `automatic-rename` window option

## What doesn't get saved

- Running processes (panes restore to a fresh shell)
- Scroll history
- Environment variables
- Pane contents

## Options

Option names still use the `@frost-*` prefix for compatibility with existing configs and save data.

Set these in `~/.tmux.conf` before loading the plugin:

```tmux
# Save/restore keybindings
set -g @frost-save-key 'C-s'        # default: C-s
set -g @frost-restore-key 'C-r'     # default: C-r

# Auto-restore on server start ('on' or 'off')
set -g @frost-auto-restore 'on'       # default: on

# Auto-save interval in minutes (0 to disable)
set -g @frost-auto-save-interval '15'  # default: 15

# Save directory
set -g @frost-dir '~/.local/share/tmux/glacier'  # default

# Delete backups older than N days (keeps newest 5 regardless)
set -g @frost-delete-backup-after '30'  # default: 30

# Restore pane titles on thaw ('on' or 'off')
set -g @frost-restore-pane-title 'off'  # default: off
```

## Save file format

Saves are tab-separated text files with a version header:

```
frost_version	1
pane	session	window_idx	win_active	pane_idx	title	:path	pane_active
window	session	window_idx	:name	win_active	:flags	layout	auto_rename
state	client_session	client_last_session
```

Files are stored as `frost_YYYYMMDDTHHMMSS.txt` with a `last` symlink pointing to the most recent save. The default save directory is `~/.local/share/tmux/glacier` (override with `@frost-dir`).

The version field is `1`. Format changes that would break existing files will increment this number. thaw rejects files with an unrecognised version header rather than silently producing a broken restore.

Filenames, option keys, and the file format remain under the `frost` name for compatibility; only the default on-disk directory uses `glacier`.

## How auto-restore works

When the plugin loads, it registers a one-shot `session-created` hook. The first time a session is created (i.e. tmux just started), the hook checks if the server is fresh (only 1 pane exists) and a save file is available. If so, it runs thaw to restore the previous layout. The hook removes itself immediately so it never fires again during the server's lifetime.

## How auto-save works

Auto-save runs as a background loop that sleeps for the configured interval and then triggers a quiet freeze. The loop is started by `glacier.tmux` when the plugin loads and is a child of the tmux server process, so it dies naturally when tmux exits. A PID file prevents duplicate loops on config reloads (`tmux source`).

## Troubleshooting

**Auto-restore didn't fire on startup**

The one-shot hook only triggers when the server is truly fresh (exactly 1 pane). If another process already created a session before the hook fired, it won't run. Check that `@frost-auto-restore` is `'on'` and that you're starting a brand-new tmux server.

**Auto-save doesn't seem to be running**

Check whether the background loop is alive:

```sh
cat ~/.local/share/tmux/glacier/.auto_save.pid | xargs kill -0 && echo running || echo dead
```

If dead, reload your config (`tmux source ~/.tmux.conf`) to restart the loop.

**How to read the logs**

tmux-glacier writes a daily log to its save directory (`frost_YYYY-MM-DD.log` under the glacier dir):

```sh
tail -f ~/.local/share/tmux/glacier/frost_$(date +%Y-%m-%d).log
```

Logs include timestamps and INFO/WARN/ERROR levels for every freeze and thaw.

**Restore produced the wrong sessions or nothing at all**

thaw reads from the `last` symlink. Verify it points to the expected file:

```sh
ls -la ~/.local/share/tmux/glacier/last
```

To restore from a specific save, update the symlink manually:

```sh
ln -fs frost_20250101T120000.txt ~/.local/share/tmux/glacier/last
```

## Running tests

```sh
make test
```

Tests run against an isolated tmux server socket and don't affect your running sessions.

## License

MIT. Based on [clanghans/tmux-frost](https://github.com/clanghans/tmux-frost); see `LICENSE` for the original copyright notice. This fork is maintained separately by shipitlater.
