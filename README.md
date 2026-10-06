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
- Window-local and pane-local user option persistence: all `@*` user options set directly on a window or pane are saved and restored separately, regardless of their names or purpose. Inherited options and other built-in options are not part of the snapshot.
- Save format version `frost_version` is written as `3`. Thaw accepts versions `1`, `2`, and `3` and rejects any other version.
- If the configured save directory is readable but not writable, Glacier performs a one-shot migrate of existing frost save files into a writable fallback directory and continues there. Invalid or dangerous `@frost-dir` values are rejected early.

## Requirements

- tmux 3.0a or newer
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
set -g @plugin 'shipitlater/tmux-glacier#v1.2.0'
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
- Window layouts and built-in window names
- Pane working directories and titles
- Active window and pane selections
- Client session state
- The `automatic-rename` window option
- Window-local `@*` user options that were set on the window itself, including empty values
- Pane-local `@*` user options that were set on the pane itself, including empty values

## What is not saved

- Running processes (panes start a fresh shell after thaw)
- Scrollback history
- Environment variables
- Pane contents
- Option names or values that contain a `NUL` byte
- Global and session options, and options inherited into windows or panes
- Built-in window and pane options other than `automatic-rename`
- Hooks and linked-window connections

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

# Confirm before restore when any session has more than one pane ('on' or 'off')
set -g @frost-thaw-confirm 'off'       # default: off
```

`@frost-dir` is validated before use. Empty values, the filesystem root, relative paths that do not expand to an absolute path, and values that contain newlines are rejected. If the directory exists and can be read but cannot be written, Glacier migrates frost save files once into a writable fallback under the default data path or, when that is also unusable, under the user cache directory, then uses that fallback for later freeze and thaw.


`@frost-thaw-confirm` defaults to `off`. When set to `on`, the restore key checks every session on the current tmux server. If every session has exactly one pane, restore runs immediately. If any session has two or more panes, tmux shows a single status-line `confirm-before` prompt ending in `(y/n)`. Only `y` runs thaw once; any other key cancels (tmux `confirm-before` default) and leaves sessions unchanged, without an error in the pane. There is no separate force key: leave the option off for the previous confirm-free path. Auto-restore never uses this prompt.

The confirm prompt appears on the tmux status line, not inside a pane or as a popup. If the status line is hidden, or no client is attached when the key runs, the prompt may be easy to miss or may not appear.

## Window-local and pane-local user options

Glacier persists arbitrary user options whose names begin with `@`, set directly on a window with `set-option -w` or on a pane with `set-option -p`. Names and values are treated as data without option-specific behavior.

For example, these options are saved and restored independently at their respective scopes:

```bash
tmux set-option -w -t my-session:1 @project 'api'
tmux set-option -w -t my-session:1 @workflow 'review'
tmux set-option -w -t my-session:1 @counter '7'
tmux set-option -p -t my-session:1.0 @project 'worker'
```

During freeze, Glacier records a `window_user_options` marker for every session/window path and a `pane_user_options` marker for every pane, including targets with no local user options. Each local `@*` option gets a `window_user_option` or `pane_user_option` record. Names and values are stored as `b64:` Base64 fields so empty values, spaces, newlines, and non-ASCII names stay exact. Window and pane options with the same name stay separate.

Built-in window names, layouts, and `automatic-rename` are stored separately in `window` records.

During thaw, targets with a valid marker have their current local `@*` options replaced by the saved set. A marker without option records clears that target's local user options. Options from higher scopes stay in place. Files without a marker for a target leave its local options untouched. Thaw resolves session names and indices exactly to current window or pane IDs. Duplicate markers replace the set once; duplicate names apply the last saved value, regardless of marker placement.

If a saved target no longer exists, thaw logs a warning and continues successfully. Corrupt option records preserve that target's existing options while other windows and panes still restore. Invalid markers are logged as errors and ignored; a valid marker for the same target still allows restoration if its option records are valid. Records without valid markers, validation errors, and lookup/unset/set failures make thaw return a nonzero status. Command failures can leave a target partly changed; thaw does not roll back. Logs omit option values and raw tmux errors. Freeze failures while listing, reading, encoding, or writing options abort the new snapshot and keep the previous snapshot and `last` link.

## Save file format

Saves are tab-separated text files. New saves start with:

```text
frost_version<TAB>3
pane<TAB>session<TAB>window_idx<TAB>win_active<TAB>pane_idx<TAB>title<TAB>:path<TAB>pane_active
pane_user_options<TAB>session<TAB>window_idx<TAB>pane_idx
pane_user_option<TAB>session<TAB>window_idx<TAB>pane_idx<TAB>b64:name<TAB>b64:value
window_user_options<TAB>session<TAB>window_idx
window_user_option<TAB>session<TAB>window_idx<TAB>b64:name<TAB>b64:value
window<TAB>session<TAB>window_idx<TAB>:name<TAB>win_active<TAB>:flags<TAB>layout<TAB>auto_rename
state<TAB>client_session<TAB>client_last_session
```

`<TAB>` is a single tab character. Thaw accepts `frost_version` values `1`, `2`, and `3`. Any other version is rejected before tmux state changes. Version `1` and `2` files without window option markers remain readable and leave window-local options untouched; the same rule applies to missing pane markers. Older readers reject version `3`. After downgrading, select a retained version `1` or `2` snapshot with `last`; Glacier does not convert snapshots automatically.

Files are named `frost_YYYYMMDDTHHMMSS.txt`. A `last` symlink points at the newest save. When two different saves would share the same timestamp, a numeric suffix such as `_1` is added. The default directory is `~/.local/share/tmux/glacier`.

## How auto-restore works

When the plugin loads, it registers a one-shot `session-created` hook. The first time a session is created on a fresh server that has only one pane and a save file is available, the hook runs thaw. The hook removes itself immediately so it does not fire again for that server.

## How auto-save works

Auto-save is a background loop started by `glacier.tmux` that runs a quiet freeze at the configured interval. It checks the original tmux server's PID every second and exits when that server exits. A PID file prevents duplicate loops after `tmux source`.

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
