# Changelog

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
