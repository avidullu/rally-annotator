# Rally Annotator

[![VLC dialog suite](https://github.com/Khelsutra/rally-annotator/actions/workflows/ci.yml/badge.svg)](https://github.com/Khelsutra/rally-annotator/actions/workflows/ci.yml)
[![web extension CI](https://github.com/Khelsutra/rally-annotator/actions/workflows/web-ci.yml/badge.svg)](https://github.com/Khelsutra/rally-annotator/actions/workflows/web-ci.yml)

> **Part of [Khelsutra](https://khelsutra.guru) — _“Every rally, indexed. The dead time, gone.”_**
> Khelsutra turns a full badminton match into a clean index of rallies with the dead time stripped out —
> a highlight reel you can watch and download. **Rally Annotator is its open labeling tool**: the
> ground-truth rally CSVs produced here are what the Khelsutra pipeline trains and evaluates its
> rally-segmentation models against. This repo is the public, open-source piece of that stack.

Hand-label rally **start/end + point-stop reason** while you watch a match, for **net-separated racquet
sports** — badminton, tennis, table tennis, pickleball, padel. Two front-ends, **same CSV**:

- 🎬 **VLC plugin** — label **local video files** inside VLC (this README); the dialog is **localized**
  (English, Hindi, Kannada, Telugu, Spanish, Danish, Indonesian) via a Language selector.
- 🌐 **Browser extension** _(new)_ — label **web video, including YouTube**, right in the page;
  **localized into English, Hindi, Kannada, Telugu, Spanish, Danish & Indonesian**. See **[web/](web/)**.

You watch the video in VLC, pause/scrub freely, and click **Mark START** / **Mark END** (with a
reason). It writes one CSV row per rally — clean ground-truth labels for training/evaluating rally
(point) segmentation models, or just for cutting highlights.

```
rally_number,start_time,end_time,ending_reason,sport,shots_count
1,8.800,11.500,winner,badminton,9
2,24.389,46.589,unforced_error,badminton,21
```

Times are **decimal seconds**; `shots_count` is an **optional** rally shot/stroke count (blank if you skip it).
See [docs/CSV_FORMAT.md](docs/CSV_FORMAT.md).

## Generating rally annotations — pick your front-end

| You're labeling… | Use | Output |
|---|---|---|
| a **local video file** | the **VLC plugin** (install + use below) | `<video>.rallies.csv` next to the file |
| **web video / YouTube** (`youtube.com/watch`) | the **browser extension** → [web/](web/) | the full CSV downloaded on each save |

Both write the **identical CSV schema**, so labels from either path feed the same Khelsutra pipeline. The
VLC flow is documented below; the browser extension has its own [README](web/README.md), a
[design doc with locked decisions](web/DESIGN.md), and a [testing strategy](web/TESTING.md). Either way the
workflow is the same: **Mark START → Mark END → pick the reason → Save**, one CSV row per rally.

## Why
Labeling rally boundaries is the slow, expensive prerequisite for any rally-detection model. Most tools
make you transcribe timestamps by hand. This lets a rater do it **inside the player they already use**,
pausing to the exact frame before each mark — turning "watch a match" into "produce golden labels."

## Install
1. Copy `vlc/rally_annotator.lua` into your VLC Lua **extensions** folder:
   - **Windows:** `%APPDATA%\vlc\lua\extensions\`
   - **macOS:** `~/Library/Application Support/org.videolan.vlc/lua/extensions/`
   - **Linux:** `~/.local/share/vlc/lua/extensions/`
   (create the `extensions` folder if it doesn't exist)
2. In VLC: **Tools → Plugins and extensions → Reload extensions** (or just restart VLC).
3. Enable it from the **View** menu → **Rally Annotator**. A small dialog opens and stays open while you watch.

Requires **VLC 3.0.x**. (VLC 4.0 changed the Lua input/listener API; targeting 3.x for now.)

## Use
**Playback is built in** — the **Back 5s · Play / Pause · Fwd 5s** row drives the VLC player from the
annotation window, so you can pause, label, and resume without ever switching to the main VLC window. **Play / Pause**
is a single toggle (it resumes when paused, pauses when playing).

1. Pick the **Sport** (it stays set across rallies).
2. When a rally begins, click **Mark START** — it snapshots the current playback time into the **Start** field
   (pause/scrub first for frame accuracy; you can also edit the field by hand).
3. When the rally ends, click **Mark END** (fills the **End** field). This *arms* the rally; nothing is written yet.
4. Choose the **Ending reason** (sits between **Mark END** and **Save Rally**; defaults to **`unknown`**), optionally
   type a **Number of shots** (the rally's shot/stroke count — leave blank to skip), then click
   **Save Rally** to write one CSV row. The reason **resets to `unknown` after every save** (and the shots field
   clears too) — so neither silently reuses the previous rally's value, and you can pick the same reason on
   consecutive rallies. Use the **Next rally #** field to resume/insert numbering anywhere.
5. **Recent rallies** list: select a row, then **Edit selected** (loads it back into the fields to fix
   start/end/reason/sport → **Save changes**) or **Delete selected**. **Undo last** removes the most recent row —
   the button shows which one, e.g. `Undo last (#7)`, and the status panel shows that row's details — or clears an
   in-progress mark, or cancels an edit.
6. **Help** button → usage + an [ending-reason decision guide](docs/ENDING_REASONS.md), rendered inside the dialog.

**Output:** `<video-stem>.rallies.csv` next to the video (falls back to your home dir if the path can't be
resolved). Re-opening the extension **continues** rally numbering from the existing file — no duplicate IDs.

**Resuming a half-finished video:** labels are saved to that CSV as you go. Open the **same video** and enable the
extension and it **reloads your existing rallies** (shown in the Recent list) and continues numbering — so you can
stop and pick up later. Easiest flow: **open the video first, then enable the extension.** If you enable it *before*
the video is loaded, that's fine too — the moment you click **Mark START** (the video is playing by then) the tool
switches to that video's own `<video-stem>.rallies.csv` and loads any rallies already saved for it, so nothing is
written to the home-dir fallback by mistake. If you switch videos with the dialog already open, click **Refresh** to
point at the current video and load its rallies. (Playback *position* isn't restored — scrub to where you stopped.)

> **Where's the help / "About" text?** The empty *"About …lua"* box under **Tools → Plugins and extensions →
> Add-ons** is VLC's own add-on info dialog; its body ("Lua script") is a constant baked into VLC and **can't be
> set by an extension**. Use the **Help** button inside the Rally Annotator dialog instead. (The descriptor's
> description does show in the *Active Extensions* tab's **"More information"** dialog, and the *Active Extensions*
> list shows the title with its version, e.g. **`Rally Annotator v1.6.3`**, so you can confirm which build is loaded.)

## Sports & taxonomy
Net-separated racquet sports share a forced/unforced-error point-stop taxonomy, so one tool covers them all:

| Sport | Notes |
|---|---|
| badminton | the reference sport |
| tennis | service_fault = fault/double-fault; let supported |
| table_tennis | let (net serve) supported; fast cadence |
| pickleball | service_fault for faults; treat "let" per local rules |
| padel | net-separated; rally boundaries as in tennis |

`ending_reason` ∈ `{unknown, winner, forced_error, unforced_error, service_fault, let, other}` — a shared
vocabulary across these sports. Keep to these values for clean downstream aggregation.

### What the ending reasons mean
`unknown` is the **default** (the field resets to it after every save); every other reason **except `winner`** is
charged to the side that **lost** the rally.

| Reason | When the rally ended because… |
|---|---|
| `unknown` | **default** — not classified yet. A save with no reason picked records `unknown` (never the previous rally's reason); set a specific reason when you can. |
| `winner` | the last shot landed **in** and went unreturned (opponent couldn't reach it / only waved). A clean ace counts here. |
| `forced_error` | the loser **missed** (out or into the net) while **under pressure** — stretched, rushed, jammed, handling the opponent's pace/spin/depth. |
| `unforced_error` | the loser **missed a routine shot** they had time **and** position to make, with little or no pressure. |
| `service_fault` | the point ended **on the serve** — into the net, out of the service box, illegal action/foot fault, or a double fault. |
| `let` | the rally is **replayed** under the rules, no point scored (e.g. a tennis/table-tennis serve net-cord that's otherwise good, outside interference). |
| `other` | none of the above — occluded footage, injury/retirement, penalty, hindrance. Use sparingly. |

**The cases people ask about:** a ball/shuttle landing **out** is the *hitter's* error → `forced_error` only if they
were under pressure, otherwise `unforced_error` (it's **never** automatically forced, and never a winner for the
opponent). **Into the net** during a rally is the same; a **serve** into the net is `service_fault`. When unsure
forced-vs-unforced, **default to `unforced_error`**. See the full decision guide with examples and per-sport rules
in **[docs/ENDING_REASONS.md](docs/ENDING_REASONS.md)** (also available via the in-plugin **Help** button).

## Roadmap
- [ ] Live-test the v1.6 dialog in VLC (single Play / Pause toggle, optional Number of shots, two-step Save,
      `unknown`-default reason, editable times, Next rally #, Recent-rallies Edit/Delete) across all five sports.
- [x] **Localization** into Khelsutra's languages + Telugu (en/hi/kn/te/es/da/id): **both front-ends
      fully localized** — the browser extension and the *entire* VLC dialog (chrome, status messages, and
      the in-dialog ending-reason guide). Machine drafts pending native review — see
      [docs/LOCALIZATION.md](docs/LOCALIZATION.md).
- [ ] Optional per-sport reason presets / hotkeys.
- [x] **Browser front-end for web video incl. YouTube** — Chrome MV3 extension emitting the same CSV
      ([web/](web/)). Firefox/Safari build legs and embedded-iframe (`youtube.com/embed`) support are
      documented follow-ups (see [web/DESIGN.md](web/DESIGN.md)).
- [ ] A `python-vlc` + Tk/Qt app with global keyboard shortcuts (S/E/1–6/U) for power users / remote raters.
- [x] Optional `shots_count` column (v1.6). Further extra columns (e.g. server/receiver) still TBD behind a toggle.

## Tests
The dialog logic has a headless test suite that stubs VLC's `vlc` API (widgets + playback), loads the real
extension, drives its callbacks, and asserts the results — run with **Lua 5.1** (the interpreter VLC 3.x embeds):

```bash
lua5.1 test/dialog_test.lua        # exit 0 = pass; covers reason reset, shots column, numbering, undo, help toggle, Play/Pause toggle
```

It covers all the logic but not VLC's GUI rendering or real playback (there's no headless VLC UI automation) — those
are checked by loading in VLC with `vlc -vv --file-logging` (must scan with no `Error loading` line) plus a manual
click-through. See [test/README.md](test/README.md).

## About Khelsutra
[Khelsutra](https://khelsutra.guru) turns a full **badminton** match into a clean **index of rallies** with
the dead time stripped out — a highlight reel you can watch and download, plus a summary. It's an
**invite-only alpha** (Bengaluru) aimed at **academies and players**, with privacy built in (your footage
stays yours; minors are protected) and a roadmap toward shot detection, deeper match analysis, per-match
history, and an AI **assistant coach** — expanding to more sports and languages over time.

**Rally Annotator is the open-source labeling tool of that stack.** The rally CSVs you produce here are the
ground truth its rally-segmentation models learn from — so better labels directly mean better auto-generated
reels. _“Every rally, indexed. The dead time, gone.”_

## Contributing
Issues and PRs welcome — live test reports per sport/OS, browser-extension features, and UX fixes. Every
change is gated by tests (which is what lets us merge outside PRs with confidence): keep the VLC suite
(`lua5.1 test/dialog_test.lua`) and the web suite (`cd web && npm test`) green and add a case for new logic.
See **[CONTRIBUTING.md](CONTRIBUTING.md)** for the full dev setup, the rigorous merge bar each PR must
pass, and how to add tests for a change.

## License
MIT — see [LICENSE](LICENSE).
