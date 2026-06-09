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
pre-commit hook.

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
- **Dialog construction** — every control (playback, Mark START/END, Save, reason dropdown) is wired to its callback.
- **Help toggle** — the dedicated help panel is added/removed on each click and the button label flips.
- **Reason field** — defaults to `unknown`, resets after every save, supports the same reason on consecutive rallies, and a no-pick save records `unknown`.
- **Numbering** — the "Next rally #" field auto-advances to the next free number, refuses a duplicate, and re-syncs after Undo so removing a rally leaves no gap.
- **CSV output** — the bytes actually written are checked (header + rows + that an undone rally is absent).
- **Playback** — `Pause` / `Play-Resume` are gated on `vlc.playlist.status()` so the toggle never flips the wrong way, and seek does relative ± with a clamp at 0.

## What it can't cover

It exercises all the **logic**, but not VLC's actual GUI rendering or real media playback —
there's no headless VLC UI automation. Those are validated separately by loading the
extension in VLC with `-vv --file-logging` (it must scan with no `Error loading` line) and a
manual click-through. See the repo root `README.md` for that flow.
