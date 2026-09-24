# Omarchy Snapshots

A bar widget for [Omarchy](https://omarchy.org) 4.x that browses your snapper snapshots, shows what changed since each one, and restores files or the whole system.

- A list of snapshots, newest first. Pre/post pairs show as one row, with the important star.
- A warning dot on the bar icon when there are no snapshots, or the newest is older than `staleDays` (default 14).
- **What changed:** changed files grouped by top-level directory, with search.
- **Diff:** a unified diff for changed text files.
- **Restore files:** tick files, confirm, and they're restored. The current state is snapshotted first.
- **Whole-system restore:** guides you through booting a snapshot from the Limine menu. Once you're running it, **Make permanent** runs `limine-snapper-restore`.
- **Manage:** "Snapshot now", delete, and mark important.

## Install

```bash
omarchy plugin add https://github.com/redglover/omarchy-snapshots.git
omarchy plugin enable io.github.redglover.snapshots
```

Open the panel from the bar icon and choose **Set up snapshot access**. You'll get one polkit password prompt.

Reading snapshots needs root (`snapper list` as a normal user prints "No permissions."). Setup installs two small helpers and a polkit policy into root-owned system paths:

| File | Mode |
|------|------|
| `/usr/local/lib/omarchy-snapshots/snapshots-read` | `root:root 0755` |
| `/usr/local/lib/omarchy-snapshots/snapshots-admin` | `root:root 0755` |
| `/usr/local/lib/omarchy-snapshots/VERSION` | `root:root 0644` |
| `/usr/share/polkit-1/actions/io.github.redglover.snapshots.policy` | `root:root 0644` |

When an update changes `helper/VERSION`, the panel offers **Update snapshot access** to reinstall them.

To uninstall, remove the plugin with `omarchy plugin remove io.github.redglover.snapshots`, then:

```bash
sudo rm -r /usr/local/lib/omarchy-snapshots /usr/share/polkit-1/actions/io.github.redglover.snapshots.policy
```

## Keyboard

| Key | Action |
|-----|--------|
| ↑ ↓ (j k) | Move, or scroll a diff |
| Enter | Open a snapshot, expand a group, or open a file's diff |
| Space | Select a file for restore |
| `/` | Search changed files |
| `n` | Focus the description field for a new snapshot |
| `i` | Toggle important |
| `x` | Delete a snapshot |
| Esc | Back, or close |

The panel registers the IPC target `snapshots`. To bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + S", "Snapshots", "omarchy-shell snapshots toggle")
```

## Settings

`staleDays` (integer, default 14) can be set on the widget's entry in `~/.config/omarchy/shell.json` or from the bar settings. The plugin works with the snapper config `root`.

## Security model

Plugins run as unsandboxed code in your shell, and the plugin folder `~/.config/omarchy/plugins/io.github.redglover.snapshots/` is writable by your user. So:

- **The panel never runs anything from the plugin folder as root, except `helper/setup`.** Every privileged call is `pkexec /usr/local/lib/omarchy-snapshots/…`, and the policy's `org.freedesktop.policykit.exec.path` points to those root-owned copies. Editing the plugin's `helper/` files changes nothing that runs as root until you run setup again, which asks for an admin password. Review `helper/` before you do.
- **`snapshots-read`** returns metadata and changed file paths only, never file contents. It's allowed without a prompt for the active local session (`allow_active=yes`, `allow_any`/`allow_inactive=no`). Commands:
  - `list <cfg>`
  - `status <cfg> <a> <b>`
  - `booted`
- **`snapshots-admin`** uses `auth_admin_keep`. Commands:
  - `diff <cfg> <a> <b> <path>` (can reveal any file, `/etc/shadow` included)
  - `undo <cfg> <n> <path>…`
  - `create <cfg> <description>`
  - `delete <cfg> <n>…`
  - `important <cfg> <yes|no> <n>…`
  - `promote`

  There are two executables because polkit sets auth rules per program, not per argument.
- **Validation in both helpers:**
  - Configs must match `^[a-z0-9_-]+$` and exist in `snapper list-configs`.
  - Snapshot IDs must be non-negative integers, and never 0 for destructive actions.
  - Paths must be absolute and contain no `..`. They must also appear in `snapper status <a>..<b>` before `diff` or `undo` touches them.
  - Descriptions are 1–200 characters with no control characters.
  - Arguments are passed as arrays, never through `eval` or a shell string.
- **`undo`** creates a "before restore from #N" snapshot, then runs `snapper undochange N..0` on exactly the chosen paths.
- **`promote`** only runs when `/proc/cmdline` shows you're booted into a snapshot. `limine-snapper-restore` asks its own questions, including whether to reboot, so the panel runs it in a floating terminal.

## Development

```bash
node tests/model-test.cjs         # parsing, grouping, dates, stale warning
bash tests/helper-args-test.sh    # helper argument validation, stubbed snapper
omarchy plugin validate .
```

For live testing, symlink the checkout into `~/.config/omarchy/plugins/io.github.redglover.snapshots` and enable it. Saving a file reloads the plugin.
