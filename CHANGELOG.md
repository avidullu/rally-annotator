# Changelog

## v1.6 — 2026-06-13
- **Single Play / Pause toggle.** The separate **Play / Resume** and **Pause** buttons are merged into one
  **Play / Pause** button, so the playback row is now just **Back 5s · Play / Pause · Fwd 5s** (3 buttons). The
  toggle branches on `vlc.playlist.status()` — pause→resume, play→pause, and a fresh `play()` from stopped — so it
  never flips the wrong way (VLC's `pause()` is a hard toggle).
- **Feature: optional "Number of shots" field → new `shots_count` CSV column.** Type a rally's shot/stroke count
  before **Save Rally** (leave blank to skip); it's appended as a 6th column
  (`rally_number,start_time,end_time,ending_reason,sport,shots_count`). The field clears after each save (non-sticky,
  like the reason), **Edit selected** reloads the saved count, and the Recent-rallies list shows it. Older 5-column
  CSVs still load (the column reads blank); readers that go by column name are unaffected.
- Dialog regrouped for the new field: **Number of shots** sits next to **Next rally #**; the reason label/dropdown
  and the Mark/Save action row shift down one row. The layout-snapshot golden (`test/dialog_layout.snapshot`) is
  regenerated for the new grid, and the suite grows to **45 assertions** (shots write/blank/edit, Play/Pause toggle),
  green via `lua5.1 test/dialog_test.lua`.

## v1.5.1 — 2026-06-09
- **UX: the annotation window title now shows the version** — the dialog opens as **"Rally Annotator v1.5.1"** instead
  of just "Rally Annotator", so a rater can tell at a glance which build they're running. The version is a single
  `VERSION` constant the descriptor and the dialog title both read, so they can't drift.
- **Test:** added two assertions that the dialog title carries the version and exactly matches `Rally Annotator v` +
  `descriptor().version`.
- **Test: layout snapshot** (`test/dialog_layout.snapshot`). The harness now serializes the full widget grid the
  extension hands to VLC — every control's kind, grid column/row, column/row span, and caption/options, plus the
  window title — and diffs it against a committed golden. It's the deterministic, cross-platform stand-in for a
  screenshot diff (VLC renders extension dialogs through Qt with no headless path), catching any moved, resized,
  renamed, added, or removed control and any title change. Regenerate intentional layout changes with
  `lua5.1 test/dialog_test.lua --update`. **39 assertions total.**
- **CI: GitHub Actions** (`.github/workflows/ci.yml`) runs on every push and PR — syntax-checks the extension with
  `luac5.1 -p` (the kind of scan-time error that silently broke loading in v1.3.1), then runs the full dialog suite
  including the layout snapshot. A status badge is on the root `README`.
- **Docs:** `test/README.md` gains a **Windows** Lua-5.1 install FAQ (no-admin portable install + the `choco` route),
  since `lua5.1` isn't on PATH by default there.

## v1.5 — 2026-06-08
- **Feature: playback controls (issue #4).** A new **Back 5s · Play / Resume · Pause · Fwd 5s** row drives the VLC
  player from the annotation window — pause, label, and resume without switching to the main VLC window. Uses the
  extension-exposed `vlc.playlist` (play/pause/status) and `vlc.var` seek on the input; Pause / Play-Resume are
  **gated on `vlc.playlist.status()`** because VLC's `pause()` is a hard toggle, so they never flip the wrong way.
  Seek is relative ±5 s, clamped at 0. (Verified feasible against the VLC 3.0 source before building.)
- **Committed test suite** (`test/dialog_test.lua`, run with `lua5.1`): stubs VLC's dialog + playback API, loads the
  real extension, and asserts reason reset / consecutive-reason / numbering / undo re-sync / help toggle / playback
  gating / CSV output — **36 assertions, exit-code-based** for CI. See `test/README.md`.
- Dialog regrouped to fit the playback row at the top; reason dropdown cell `(3,4)` → `(3,5)`, help panel row `14` → `15`.

## v1.4 — 2026-06-08
- **Fix: the Help button now toggles reliably.** It previously got "stuck" showing help — VLC didn't repaint the
  in-place text swap on the shared status widget. Help is now a **dedicated panel** added/removed via
  `add_html`/`del_widget`, which forces a real layout change VLC renders every time. (Verified with a headless
  `lua5.1` harness that stubs the VLC dialog API and drives the toggle.)
- **Feature: "Next rally #" field** — choose where numbering resumes from (restart at 1, continue from 50, fill a
  gap, …). Defaults to the natural next number, auto-advances to the next **free** number after each save, and
  refuses a number that already exists in the CSV. The Save button shows the number it will write.
- **Fix: the Ending reason no longer gets "stuck".** Picking a reason (e.g. `winner`) used to block the next rally
  from using the same one — VLC didn't repaint the `clear()`-based dropdown reset. The reason now resets to a real,
  savable **`unknown`** default by recreating the dropdown (same `del_widget` technique as Help), so consecutive
  rallies can share a reason and a forgotten pick records `unknown` rather than the previous rally's reason. Reason
  is no longer a hard-required field; `unknown` was added to the documented vocabulary.
- **Fix: removing a rally no longer leaves a numbering gap.** `Undo last` and `Delete selected` now re-sync the
  "Next rally #" field to the current data.

## v1.3.1 — 2026-06-08
- **Fix: the extension failed to load and never appeared under the View menu.** v1.3 built the `REASON_ID`/`SPORT_ID`
  lookup tables with **top-level `ipairs` loops**, which run during VLC's *descriptor scan* — a restricted Lua sandbox
  that does not expose base globals like `ipairs` — so the whole script errored at scan time
  (`attempt to call global 'ipairs' (a nil value)`) and VLC skipped it. Moved that table-building into `activate()`
  (the full Lua environment); no top-level code now calls any global function. Verified via VLC's `-vv` extension-scan log.

## v1.3 — 2026-06-08
- **Ending reason is now required and non-sticky:** a `-- choose reason --` placeholder is the default, Save is
  refused until a real reason is picked, and the reason **resets after every save** (fixes the bug where the
  previous rally's reason was silently reused).
- **Two-step commit:** `Mark END` now *arms* the rally; you pick the reason and click **Save Rally** to write it
  (the button shows the rally number it will write). Per-rally reasons are captured at save time.
- **Editable Start/End fields** — fine-tune the marked seconds before saving.
- **Edit recent rallies:** a *Recent rallies* list with **Edit selected** / **Delete selected**; `Undo last`
  removes the most recent row, clears an in-progress mark, or cancels an edit. `Undo last` now shows **which** row
  it will remove (`Undo last (#N)`) and the status panel shows that row's details. CSV is now rewritten atomically
  (tmp + rename, with a Windows `.bak` rollback) and preserves any extra columns.
- **Resume a half-finished video:** on activate the extension reloads that video's existing `.rallies.csv` (shown
  in the Recent list, with continued numbering); **Refresh** now re-points to whatever video is playing and loads
  its rallies — so reopening (or switching) videos picks up where you left off. (Playback position isn't restored.)
- **In-dialog Help button** — usage + an ending-reason decision guide, rendered inside the extension's own dialog
  (VLC's own *About* dialog shows a hardcoded "Lua script" and cannot be set by an extension). New repo guide
  `docs/ENDING_REASONS.md`; README gains reason definitions and the out-of-bounds / into-net / net-cord rulings.
- Richer `descriptor()` `shortdesc`/`description` (these surface in the *Active Extensions* tab's "More information").

## v1.2 — 2026-06-07
- Generalized from badminton-only to **net-separated racquet sports** (badminton, tennis, table tennis,
  pickleball, padel) via a new **Sport** dropdown and a `sport` CSV column.
- Generic naming/branding; MIT-licensed standalone release.

## v1.1 (badminton-only, pre-release; from badminton-highlight-indexer)
- Button-driven dialog (not an auto-pause hook — that VLC callback is flaky on macOS / broken in VLC 4.0).
- Snapshots `vlc.var.get(input,"time")/1e6` (microseconds → seconds).
- Continues rally numbering across re-enable (no duplicate `rally_number`); one-level Undo; HTML status panel.
- Writes `rally_number,start_time,end_time,ending_reason` next to the video.

> Note: v1.2 changes the multi-sport path and is **pending a live VLC smoke test** across all five sports.
