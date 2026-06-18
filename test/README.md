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
pre-commit hook. **GitHub Actions runs it on every push and PR** ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)):
it syntax-checks the extension with `luac5.1 -p`, then runs this suite (logic **+ the layout snapshot**).

### Installing Lua 5.1

- **Debian/Ubuntu (incl. WSL):** `sudo apt install -y lua5.1`
- **macOS:** `brew install lua@5.1`
- **Windows — no admin, portable (recommended):** download the official LuaBinaries 5.1.5 build and unzip it into
  your user folder. PowerShell:

  ```powershell
  $dir = "$env:USERPROFILE\tools\lua515"
  New-Item -ItemType Directory -Force $dir | Out-Null
  $zip = "$env:TEMP\lua515.zip"
  # Use the direct file host (the SourceForge "/download" page is HTML, not the zip):
  Invoke-WebRequest "https://master.dl.sourceforge.net/project/luabinaries/5.1.5/Tools%20Executables/lua-5.1.5_Win64_bin.zip?viasf=1" -OutFile $zip -UseBasicParsing
  Expand-Archive $zip -DestinationPath $dir -Force
  & "$dir\lua5.1.exe" -v          # -> Lua 5.1.5
  & "$dir\lua5.1.exe" test\dialog_test.lua   # run the suite (from repo root)
  ```

  Add `"$env:USERPROFILE\tools\lua515"` to your PATH to call `lua5.1` directly.
- **Windows — with admin:** in an **elevated** PowerShell (Chocolatey needs admin, so a normal shell fails with
  `Access to the path ...chocolatey... is denied`): `choco install lua51 -y`.

Why 5.1 specifically: it's the interpreter VLC 3.x embeds, so the test's syntax/semantics match what ships in VLC.

## What it covers

- **Load safety** — `descriptor()` returns valid metadata and the version is current.
- **Window title** — the dialog title carries the version and stays exactly in sync with `descriptor().version`.
- **Layout snapshot** — the full widget grid (every control's kind, grid column/row, column/row span, and
  caption/options) plus the window title are serialized and diffed against a committed golden,
  `dialog_layout.snapshot` (see below).
- **Dialog construction** — every control (playback, Mark START/END, Save, reason dropdown, Number of shots input) is wired to its callback / present at its grid cell.
- **Help toggle** — the dedicated help panel is added/removed on each click and the button label flips.
- **Reason field** — defaults to `unknown`, resets after every save, supports the same reason on consecutive rallies, and a no-pick save records `unknown`.
- **Shots field** — the optional `shots_count` is written when entered, left blank when not, clears after each save, and is reloaded by **Edit selected** (and the edit rewrites it).
- **Recent list** — loading a 13-rally CSV lists **all** of them (oldest first, newest last), with no "last N" cap hiding the earliest rallies.
- **Resume / CSV adoption** — enabling with no media (home fallback) then "playing" a video and clicking **Mark START** adopts `<video>.rallies.csv`, loads the rallies already saved for it, writes new ones there, and never touches the home fallback.
- **Numbering** — the "Next rally #" field auto-advances to the next free number, refuses a duplicate, and re-syncs after Undo so removing a rally leaves no gap.
- **CSV output** — the bytes actually written are checked (6-column header + rows + the shots column + that an undone rally is absent).
- **Playback** — the single **Play / Pause** toggle branches on `vlc.playlist.status()` so it never flips the wrong way (and starts fresh from stopped), and seek does relative ± with a clamp at 0.

## Layout snapshot (`dialog_layout.snapshot`)

VLC renders extension dialogs through its Qt GUI and has **no headless/offscreen rendering path**, and **no CLI
flag to auto-open a Lua extension** — so a real pixel screenshot can't be captured in an automated, deterministic,
cross-platform way (it would need a virtual display + scripted menu clicks + flaky pixel diffs). Instead the test
captures the **widget tree the extension hands to VLC** — the same thing VLC turns into pixels — and diffs it
against a committed golden:

```
title :: Rally Annotator v1.6
 1. label      @(1,1) 1x1 :: Sport:
 2. dropdown   @(2,1) 2x1 :: [badminton, tennis, table_tennis, pickleball, padel]
 ...
18. dropdown   @(3,6) 1x1 :: [unknown, winner, forced_error, unforced_error, service_fault, let, other]
```

Each line is a control's `kind @(column,row) WxH :: caption` (dropdowns list their options; the dynamic status/help
HTML and the recent-rallies list are shown as placeholders since their bodies are runtime data, not layout). It's
captured right after `activate()`, in the dialog's pristine initial state. A moved, resized, renamed, added, or
removed control — or a changed window title — fails the test with a line-by-line `want`/`got` diff.

When you change the layout **on purpose**, regenerate the golden and commit it:

```bash
lua5.1 test/dialog_test.lua --update      # or: UPDATE_SNAPSHOT=1 lua5.1 test/dialog_test.lua
```

## What it can't cover

It exercises all the **logic** and the **declared layout**, but not VLC's actual GUI *rendering* (real fonts, Qt
theming, DPI) or real media playback — there's no headless VLC UI automation. Those are validated separately by
loading the extension in VLC with `-vv --file-logging` (it must scan with no `Error loading` line) and a manual
click-through. See the repo root `README.md` for that flow.
