# Tests

The extension (`vlc/rally_annotator.lua`) is a single Lua file that only talks to VLC
through the global `vlc` table. `dialog_test.lua` **stubs that table** (dialog widgets +
playback) in pure Lua, loads the real extension, drives its callbacks, and asserts the
resulting state.

## Run

Use **Lua 5.1** — the same interpreter VLC 3.x embeds, so the syntax/semantics match:

```bash
lua5.1 test/dialog_test.lua        # from the repo root
```

Exit code is `0` if all assertions pass, `1` otherwise — so it drops straight into CI or a
pre-commit hook. On Debian/Ubuntu (incl. WSL): `sudo apt install -y lua5.1`.

## What it covers

- **Load safety** — `descriptor()` returns valid metadata and the version is current.
- **Dialog construction** — every control (playback, Mark START/END, Save, reason dropdown, Number of shots input) is wired to its callback / present at its grid cell.
- **Help toggle** — the dedicated help panel is added/removed on each click and the button label flips.
- **Reason field** — defaults to `unknown`, resets after every save, supports the same reason on consecutive rallies, and a no-pick save records `unknown`.
- **Shots field** — the optional `shots_count` is written when entered, left blank when not, clears after each save, and is reloaded by **Edit selected** (and the edit rewrites it).
- **Numbering** — the "Next rally #" field auto-advances to the next free number, refuses a duplicate, and re-syncs after Undo so removing a rally leaves no gap.
- **CSV output** — the bytes actually written are checked (6-column header + rows + the shots column + that an undone rally is absent).
- **Playback** — the single **Play / Pause** toggle branches on `vlc.playlist.status()` so it never flips the wrong way (and starts fresh from stopped), and seek does relative ± with a clamp at 0.

## What it can't cover

It exercises all the **logic**, but not VLC's actual GUI rendering or real media playback —
there's no headless VLC UI automation. Those are validated separately by loading the
extension in VLC with `-vv --file-logging` (it must scan with no `Error loading` line) and a
manual click-through. See the repo root `README.md` for that flow.
