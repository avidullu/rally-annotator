# Rally Annotator — browser extension (web port)

A Manifest V3 browser extension that brings the [VLC rally annotator](../vlc/rally_annotator.lua)
to **web video**: open a page with a playing HTML5 `<video>`, mark each rally's START/END +
ending reason, and get the **same CSV** (`rally_number,start_time,end_time,ending_reason,sport,shots_count`)
that feeds the Khelsutra rally-segmentation pipeline.

> Part of **[Khelsutra](https://khelsutra.guru)** — _“Every rally, indexed. The dead time, gone.”_ This is
> the web front-end of Khelsutra's open rally-labeling tool. **Docs:** [DESIGN.md](DESIGN.md) (architecture +
> locked decisions) · [TESTING.md](TESTING.md) (test strategy + per-browser proof) · [../CONTRIBUTING.md](../CONTRIBUTING.md).

**Chrome-first, loaded unpacked.** Built as one cross-browser-ready codebase (WXT); Firefox + Safari
+ store publishing are the north star (low-rework follow-ups), not yet wired.

## Status (v0.1.0)

Works now:
- Full v1.7.1 dialog parity: two-step Mark→Save, non-sticky reason (default `unknown`), sticky
  sport, editable Start/End, `Next rally #` continuity + auto-advance, **Number of shots**, 3-way
  Undo, edit-mode **Re-mark (#N)** relabel, **unsaved-rally guard**, recent-rallies list (all,
  oldest-first), Back 5s / Play-Pause / Fwd 5s.
- **Localized into 7 languages** (English, Hindi, Kannada, Telugu, Spanish, Danish, Indonesian) with a
  persisted in-panel language selector — machine-draft translations pending native review (see
  [../docs/LOCALIZATION.md](../docs/LOCALIZATION.md)).
- Controls any **direct HTML5 `<video>`** in the top frame, including videos in (open/closed)
  shadow DOM and **youtube.com/watch** (its player is in the main page).
- Rallies autosave to extension storage keyed per video → reloading the page resumes numbering.
- The full CSV downloads on each Save (and via the **Download CSV** button).

Not yet (deliberate follow-ups):
- **YouTube/Vimeo embeds on third-party pages** (cross-origin `<iframe>`) — needs a per-provider
  handler injected into the provider frame.
- Firefox/Safari build legs and store publishing.
- `showSaveFilePicker` single-file "rewrite one CSV" mode (Chrome/Edge only).

## Load it in Chrome

```
cd web
npm install
npm run build      # outputs web/.output/chrome-mv3
```

Then: `chrome://extensions` → enable **Developer mode** → **Load unpacked** → select
`web/.output/chrome-mv3`. Open a page with a video and **click the extension's toolbar icon** to
show/hide the panel. Drag it by its header; it stays visible over fullscreen video (desktop).

`npm run dev` runs WXT in watch mode (auto-reload) if you prefer.

## Develop / test

Proof-and-validation driven — see [TESTING.md](TESTING.md) for the full strategy and the
per-browser proof matrix.

```
npm test          # Vitest: CSV round-trip (byte-identical to the VLC tool) + state-machine + DOM
npm run coverage  # unit + enforced coverage thresholds (~98% stmts/lines/funcs)
npm run typecheck
npm run build
npm run e2e        # real-Chromium E2E that loads the built extension and records a screencast
```

CI (`.github/workflows/web-ci.yml`) runs all of the above on every change under `web/` and
uploads the E2E screencast + coverage as artifacts.

## Architecture

- `src/state/csv.ts` — CSV serialize/parse, **byte-compatible** with the Lua `save_all`/`load_rows`.
- `src/state/annotator.ts` — pure state machine ported ~1:1 from the Lua callbacks (numbering, undo,
  guards, labels); unit-tested, no browser needed.
- `src/video/directVideo.ts` — finds/controls the active `<video>` (seconds, no µs conversion).
- `src/persist/store.ts` — `chrome.storage.local` live store + per-video identity + CSV filename.
  (Extension-scoped on purpose — a content script's IndexedDB would live in the visited site's
  origin. IndexedDB-in-service-worker is the path if storage ever needs to scale.)
- `src/ui/panel.ts` — open-shadow-DOM panel reproducing the VLC widget set (open = same CSS
  isolation as closed, but reachable by automation/devtools).
- `entrypoints/content.ts` — top-frame bootstrap; `entrypoints/background.ts` — CSV download + icon toggle.

## Output

The CSV is downloaded to your **Downloads** folder as `<page-title>.rallies.csv` (a sandboxed
extension can't write next to a web video). It is identical in schema to the VLC tool's output — see
[../docs/CSV_FORMAT.md](../docs/CSV_FORMAT.md).
