# tmux-glacier

This project is a hard fork of [clanghans/tmux-frost](https://github.com/clanghans/tmux-frost).

It keeps the same freeze and thaw workflow while adding bug fixes, macOS compatibility, and more features.

## Overview

tmux-glacier saves your tmux sessions to a text snapshot and restores them later. It is a single plugin for save, restore, and optional auto-save or auto-restore. It does not rewrite your status bar, and it does not try to resurrect running processes.

The public product name is Glacier. On-disk file names, option keys, and format headers still use the upstream `frost` protocol names so existing configs and save files keep working.

## Features

- Save and restore sessions, windows, panes, and layouts.
- Auto-restore on a fresh server start when enabled.
- Auto-save on a configurable interval (default 15 minutes).
- Stacked-pane layout repair at save time: broken layouts with tiny panes become `tiled`.
- Deduplicated saves: identical content does not create a new file.
- Backup retention: old saves are removed after a configurable age while keeping the newest few.
- Locking so concurrent freeze and thaw do not race.
- Pane-local user option persistence: options set directly on a pane with `@*` names are saved and restored per pane. Inherited global, session, or window options and built-in pane options are not part of the snapshot.
- Save format version `frost_version` is written as `2`. Thaw accepts versions `1` and `2` and rejects any other version.
- If the configured save directory is readable but not writable, Glacier performs a one-shot migrate of existing frost save files into a writable fallback directory and continues there. Invalid or dangerous `@frost-dir` values are rejected early.

## Requirements

- tmux 3.0 or newer
- bash
- [TPM](https://github.com/tmux-plugins/tpm)

## Install

Add this line to `~/.tmux.conf`:

```tmux
set -g @plugin 'shipitlater/tmux-glacier'
```

Reload tmux and press `prefix + I` to install. TPM loads the plugin through the `glacier.tmux` entrypoint.

To pin a release tag:

```tmux
set -g @plugin 'shipitlater/tmux-glacier#v1.1'
```

Pinned installs do not move when you press `prefix + U`. Change the tag and reinstall to upgrade.

## Keybindings

| Binding | Action |
|---|---|
| `prefix + C-s` | Save (freeze) all sessions |
| `prefix + C-r` | Restore (thaw) from the last save |

The verbs **save** and **restore** are the user-facing actions. **Freeze** and **thaw** are the same operations and match the script names `freeze.sh` and `thaw.sh`.

## What is saved

- All sessions, windows, and panes
- Window layouts and names
- Pane working directories and titles
- Active window and pane selections
- Client session state
- The `automatic-rename` window option
- Pane-local `@*` user options that were set on the pane itself, including empty values

## What is not saved

- Running processes (panes start a fresh shell after thaw)
- Scrollback history
- Environment variables
- Pane contents
- Option names or values that contain a `NUL` byte
- Options inherited from global, session, or window scope
- Built-in pane options that are not user `@*` options

## Options

Option keys keep the `@frost-*` prefix for compatibility with existing configs and save data.

Set them in `~/.tmux.conf` before the plugin loads:

```tmux
# Save and restore keybindings
set -g @frost-save-key 'C-s'        # default: C-s
set -g @frost-restore-key 'C-r'     # default: C-r

# Auto-restore on server start ('on' or 'off')
set -g @frost-auto-restore 'on'       # default: on

# Auto-save interval in minutes (0 disables)
set -g @frost-auto-save-interval '15'  # default: 15

# Save directory (must expand to an absolute path)
set -g @frost-dir '~/.local/share/tmux/glacier'  # default

# Delete backups older than N days (newest 5 are always kept)
set -g @frost-delete-backup-after '30'  # default: 30

# Restore pane titles on thaw ('on' or 'off')
set -g @frost-restore-pane-title 'off'  # default: off
```

`@frost-dir` is validated before use. Empty values, the filesystem root, relative paths that do not expand to an absolute path, and values that contain newlines are rejected. If the directory exists and can be read but cannot be written, Glacier migrates frost save files once into a writable fallback under the default data path or, when that is also unusable, under the user cache directory, then uses that fallback for later freeze and thaw.

## Pane-local user options

During freeze, Glacier records a `pane_user_options` marker for every pane and one `pane_user_option` line for each local `@*` option on that pane. Names and values are stored as `b64:` Base64 fields so empty values, spaces, newlines, and non-ASCII names stay exact.

During thaw, panes that have a marker in the save file have their current local `@*` options replaced by the saved set. Options that appeared later on that pane are removed. Options that come from a higher scope stay in place. Older save files without markers leave current pane options untouched.

If a saved pane target no longer exists, thaw logs a warning and continues successfully so other panes can still restore. Corrupt records for one pane preserve that pane's existing options and do not stop other panes. Freeze failures while listing, reading, encoding, or writing options abort the new snapshot and keep the previous `last` link.

## Save file format

Saves are tab-separated text files. New saves start with:

```text
frost_version<TAB>2
pane<TAB>session<TAB>window_idx<TAB>win_active<TAB>pane_idx<TAB>title<TAB>:path<TAB>pane_active
pane_user_options<TAB>session<TAB>window_idx<TAB>pane_idx
pane_user_option<TAB>session<TAB>window_idx<TAB>pane_idx<TAB>b64:name<TAB>b64:value
window<TAB>session<TAB>window_idx<TAB>:name<TAB>win_active<TAB>:flags<TAB>layout<TAB>auto_rename
state<TAB>client_session<TAB>client_last_session
```

`<TAB>` is a single tab character. Thaw accepts `frost_version` values `1` and `2`. Any other version is rejected with an error. Version `1` files without pane option markers remain readable and do not change pane-local options.

Files are named `frost_YYYYMMDDTHHMMSS.txt`. A `last` symlink points at the newest save. When two different saves would share the same timestamp, a numeric suffix such as `_1` is added. The default directory is `~/.local/share/tmux/glacier`.

## How auto-restore works

When the plugin loads, it registers a one-shot `session-created` hook. The first time a session is created on a fresh server that has only one pane and a save file is available, the hook runs thaw. The hook removes itself immediately so it does not fire again for that server.

## How auto-save works

Auto-save is a background loop that sleeps for the configured interval and then runs a quiet freeze. The loop is started by `glacier.tmux` and is a child of the tmux server, so it exits when tmux exits. A PID file prevents duplicate loops after `tmux source`.

## Troubleshooting

**Auto-restore did not run on startup**

The one-shot hook only runs when the server is fresh (exactly one pane). If another process already created a session, the hook will not restore. Confirm `@frost-auto-restore` is `on` and that you started a new tmux server.

**Auto-save does not seem to be running**

Check whether the background loop is alive:

```sh
cat ~/.local/share/tmux/glacier/.auto_save.pid | xargs kill -0 && echo running || echo dead
```

If it is dead, reload your config with `tmux source ~/.tmux.conf` to restart the loop.

**How to read the logs**

Daily logs live next to the saves as `frost_YYYY-MM-DD.log`:

```sh
tail -f ~/.local/share/tmux/glacier/frost_$(date +%Y-%m-%d).log
```

Entries use timestamps and INFO, WARN, or ERROR levels for freeze and thaw.

**Restore used the wrong save or restored nothing**

Thaw follows the `last` symlink. Confirm it points where you expect:

```sh
ls -la ~/.local/share/tmux/glacier/last
```

To restore a specific file, update the symlink:

```sh
ln -fs frost_20250101T120000.txt ~/.local/share/tmux/glacier/last
```

**Save directory is read-only or `@frost-dir` was rejected**

Check the log for a migrate warning or a validation error. Fix `@frost-dir` to an absolute writable path, or allow Glacier to finish the one-shot migrate into the fallback directory.

## Running tests

```sh
make test
```

Tests use an isolated tmux server socket and do not touch your live sessions. The Makefile runs them with `/bin/bash`.

## License

MIT. Based on [clanghans/tmux-frost](https://github.com/clanghans/tmux-frost); see `LICENSE` for the original copyright notice. This fork is maintained separately by shipitlater.
