# Rally Annotator

A tiny **VLC plugin** to hand-label rally **start/end + point-stop reason** while you watch a match,
for **net-separated racquet sports** — badminton, tennis, table tennis, pickleball, padel.

You watch the video in VLC, pause/scrub freely, and click **Mark START** / **Mark END** (with a
reason). It writes one CSV row per rally — clean ground-truth labels for training/evaluating rally
(point) segmentation models, or just for cutting highlights.

```
rally_number,start_time,end_time,ending_reason,sport
1,8.800,11.500,winner,badminton
2,24.389,46.589,unforced_error,badminton
```

Times are **decimal seconds**. See [docs/CSV_FORMAT.md](docs/CSV_FORMAT.md).

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
1. Pick the **Sport** (it stays set across rallies).
2. When a rally begins, click **Mark START** — it snapshots the current playback time into the **Start** field
   (pause/scrub first for frame accuracy; you can also edit the field by hand).
3. When the rally ends, click **Mark END** (fills the **End** field). This *arms* the rally; nothing is written yet.
4. Choose the **Ending reason** — it is **required** — and click **Save Rally** to write one CSV row.
   The reason **resets after every save**, so it can't silently reuse the previous rally's reason.
5. **Recent rallies** list: select a row, then **Edit selected** (loads it back into the fields to fix
   start/end/reason/sport → **Save changes**) or **Delete selected**. **Undo last** removes the most recent row —
   the button shows which one, e.g. `Undo last (#7)`, and the status panel shows that row's details — or clears an
   in-progress mark, or cancels an edit.
6. **Help** button → usage + an [ending-reason decision guide](docs/ENDING_REASONS.md), rendered inside the dialog.

**Output:** `<video-stem>.rallies.csv` next to the video (falls back to your home dir if the path can't be
resolved). Re-opening the extension **continues** rally numbering from the existing file — no duplicate IDs.

**Resuming a half-finished video:** labels are saved to that CSV as you go. Open the **same video** and enable the
extension and it **reloads your existing rallies** (shown in the Recent list) and continues numbering — so you can
stop and pick up later. Easiest flow: **open the video first, then enable the extension.** If you switch videos with
the dialog already open, click **Refresh** to point at the current video and load its rallies. (Playback *position*
isn't restored — scrub to where you stopped.)

> **Where's the help / "About" text?** The empty *"About …lua"* box under **Tools → Plugins and extensions →
> Add-ons** is VLC's own add-on info dialog; its body ("Lua script") is a constant baked into VLC and **can't be
> set by an extension**. Use the **Help** button inside the Rally Annotator dialog instead. (The descriptor's
> description does show in the *Active Extensions* tab's **"More information"** dialog.)

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
- [ ] Live-test the v1.3 dialog in VLC (two-step Save, required/non-sticky reason, editable times, Recent-rallies
      Edit/Delete) across all five sports.
- [ ] Optional per-sport reason presets / hotkeys.
- [ ] Alternative front-ends for power users / remote raters: a `python-vlc` + Tk/Qt app with global keyboard
      shortcuts (S/E/1–6/U), and a zero-install HTML5 `<video>` page that exports the same CSV.
- [ ] Optional extra columns (e.g. `shots_count`, server/receiver) behind a toggle.

## Contributing
Issues and PRs welcome — especially live test reports per sport/OS and small UX fixes. The plugin is a single
self-contained Lua file (`vlc/rally_annotator.lua`) using only documented VLC 3.x Lua APIs.

## License
MIT — see [LICENSE](LICENSE).
