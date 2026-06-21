# Rally Annotator (web extension) — design & locked decisions

> Part of **[Khelsutra](https://khelsutra.guru)** — _“Every rally, indexed. The dead time, gone.”_
> Rally Annotator is Khelsutra's open labeling tool. The browser extension lets a rater produce
> ground-truth rally CSVs from **web video (incl. YouTube)**; those CSVs feed the same
> rally-segmentation pipeline as the VLC plugin.

This document records the **design** and the **locked decisions** behind the web extension, with the
research that justifies each one. "Locked" means: settled, implemented, and not to be revisited
without a new decision entry here (and a corresponding PR). Defer/north-star items are listed at the end.

## Where this fits in the Khelsutra stack

```
        ┌───────────────────────────── label (ground truth) ─────────────────────────────┐
        │                                                                                  │
  VLC plugin  (local files)  ─┐                                                            │
                              ├─►  <video>.rallies.csv  ──►  curation / export  ──►  AI rally indexer
  Browser extension (web,    ─┘     (shared schema)                                  ("every rally, indexed")
  incl. youtube.com/watch)
```

`rally-annotator` is the **public** piece. The curation/export and AI-indexer components are separate
(private) repos in the Khelsutra org. The contract between them is the CSV schema
([../docs/CSV_FORMAT.md](../docs/CSV_FORMAT.md)) — which the web extension reproduces **byte-for-byte**.

## Goals

- Reproduce the VLC tool's labeling UX (the v1.6.4 dialog) and its **exact CSV output** on web video.
- Be trivially installable (Chrome, unpacked) for a rater today, and structured so Firefox/Safari and
  store distribution are low-rework later.
- Lose no work: autosave every mark; never silently discard an unsaved rally.

## Non-goals (for now)

- Pixel/frame analysis of the video (timing/control only — DRM blocks pixels anyway).
- Controlling arbitrary cross-origin embedded players with zero per-provider work (see LD-2).
- A hosted/account-based sync backend.

## Architecture

One Manifest V3 source tree, built per-browser by **WXT**. The pure logic is browser-free and
unit-tested; the browser glue is thin and proven by an end-to-end test.

| Layer | Module | Responsibility |
|---|---|---|
| State (pure) | `src/state/annotator.ts` | numbering, two-step save, non-sticky reason, 3-way undo, unsaved guard, edit relabels, button labels |
| State (pure) | `src/state/csv.ts` | serialize/parse, **byte-compatible** with the Lua `save_all`/`load_rows` |
| Video | `src/video/directVideo.ts` | find/observe/control the active `<video>` (seconds; shadow-DOM aware) |
| Persist | `src/persist/store.ts` | `chrome.storage.local` live store + per-video identity + CSV filename |
| UI | `src/ui/panel.ts` | open-shadow-DOM panel, full widget parity, draggable, fullscreen-aware |
| Glue | `entrypoints/content.ts` | top-frame bootstrap: wire state ↔ video ↔ store ↔ panel |
| Glue | `entrypoints/background.ts` | CSV download (chrome.downloads) + toolbar-icon → panel toggle |

## Locked decisions

Each decision: **Status: LOCKED** unless noted. Change them only by adding a new entry here in a PR.

### LD-1 — Manifest V3, one cross-browser codebase (WXT); Chrome-first, unpacked
**Decision.** Build one MV3 source tree with WXT; ship Chrome first, loaded unpacked. Firefox + Safari +
store publishing are deferred but kept low-rework (dual background handling, promise-based `browser.*`).
**Why.** Chrome MV2 is fully removed (2025); MV3 is the only forward target. WXT emits per-browser
bundles and manages the background service-worker (Chrome) vs event-page (Firefox) split. Unpacked load
needs no store review — fastest path to a usable tool.
**Consequence.** Safari is the heavy long pole (Xcode wrapper, $99/yr, **App-Store-only** distribution —
no Developer ID direct-install); see LD-9. Firefox extension E2E needs a different harness (LD-8).

### LD-2 — Video scope: direct `<video>` + `youtube.com/watch`; cross-origin embeds deferred
**Decision.** Support any directly-reachable HTML5 `<video>` (incl. open/closed shadow DOM) in the top
frame — which includes **youtube.com/watch** (its player is in the main page). **Embedded** players on
third-party pages (a `youtube.com/embed` `<iframe>`) are **out of scope for v1**.
**Why (verified).** Same-origin policy means a top-frame content script **cannot** reach a cross-origin
iframe's `<video>`. The only path is injecting a content script **into the provider's own frame** (host
permission for that origin) — a dedicated, maintenance-heavy per-provider handler that tracks the
provider's internal markup. "Works on any embedded video" is not honestly deliverable without that.
**Consequence.** The dominant real-world embed case (YouTube on someone else's page) needs the deferred
handler in LD-10. youtube.com/watch already works because it is same-origin/top-frame.

### LD-3 — Output: byte-compatible CSV, downloaded on each Save
**Decision.** Produce the **same CSV schema** as the VLC tool and **download the full CSV on each Save**.
**Why (verified).** A sandboxed extension **cannot** write `<video>.rallies.csv` next to the file like
VLC does. `chrome.downloads` only writes into Downloads (relative paths). Byte-compatibility keeps the
pipeline ingest unchanged.
**Consequence.** `chrome.downloads` `conflictAction:"overwrite"` is **not reliable** across browser
download settings (may produce `name (1).csv`). Acceptable because the live store (LD-4) is the source of
truth and every export is a full, correct re-serialization. The single-file "rewrite one CSV" mode is
deferred (LD-11).

### LD-4 — Live store: `chrome.storage.local` keyed per video (not content-script IndexedDB)
**Decision.** Hold rallies in `chrome.storage.local`, keyed by a canonical per-video identity; derive
resume-numbering from it (max + 1), exactly like VLC's `next_rally_number()`.
**Why.** IndexedDB opened from a **content script** lives in the **visited site's** origin (evictable,
wrong scope, leaks across sites). `chrome.storage.local` is **extension-scoped**, content-script
accessible, and ample for per-video rally data.
**Consequence.** ~10 MB default cap (fine here). If storage ever needs to scale or be queryable,
**IndexedDB in the service worker** (message-passed) is the documented escalation path.

### LD-5 — UI: open Shadow DOM
**Decision.** Render the panel in an **open** shadow root.
**Why.** Open and closed give **identical CSS isolation**; "closed" is not a real security boundary (the
host page can hook `attachShadow`). Open keeps the panel reachable by automation/devtools — which is what
makes the E2E (LD-8) possible.

### LD-6 — Time base: seconds (no microseconds)
**Decision.** Read/write `video.currentTime` directly (float seconds); CSV times stay 3-dp seconds.
**Why.** HTML5 media time is already seconds, unlike VLC's microseconds — the conversion simply disappears.
**Note (verified).** Some UAs reduce `currentTime` precision (Firefox ~2 ms by default); don't assume sub-ms.

### LD-7 — Panel hidden by default; toolbar icon toggles
**Decision.** The content script mounts the panel **hidden**; clicking the extension's toolbar icon
toggles it (routed via the background SW).
**Why.** Auto-showing a panel on every page (the content script matches `<all_urls>`) is intrusive. The
icon is an explicit "annotate this page" gesture.

### LD-8 — Testing is proof-and-validation driven; it is the merge gate
**Decision.** Unit + jsdom tests with **enforced coverage thresholds**, **plus** a real-Chromium
Playwright E2E that loads the built extension and records a screencast, **plus** CI that runs all of it.
A PR merges only when this is green.
**Why.** "It works" must be evidence, not a claim — especially so outside contributors' PRs can be
trusted. Browser-only behavior is proven by the E2E rather than asserted. See [TESTING.md](TESTING.md).

### LD-9 — Safari is App-Store-only (deferred)
**Decision (verified).** Safari Web Extensions reach end users **only via the App Store** (macOS + iOS) —
there is no Developer ID direct-install. They require a Mac + `xcrun safari-web-extension-converter`.
**Consequence.** Safari cannot be built or E2E-tested on Windows or default CI runners; it is documented,
not implemented.

### LD-12 — Localization (i18n) mirrors Khelsutra
**Decision.** The panel UI is localized into Khelsutra's locales **+ Telugu** (`en, kn, hi, es, da, id,
te`) via a dependency-free `t()` shim over a shared `common.json` catalog, mirroring Khelsutra's i18n
foundation (keys-not-prose, ICU-lite, always-fall-back-to-`en`, key-parity + no-bare-strings CI gates,
OFL Noto fonts, AI-draft → native-review). The reason/sport **values** and CSV header stay canonical
English (LD-3 byte-compatibility is preserved across all languages). Full design + locked decisions:
[../docs/LOCALIZATION.md](../docs/LOCALIZATION.md).

## Deferred / north star (not locked — tracked work)

- **LD-10 — YouTube/Vimeo embed handler.** Inject into the provider frame (`all_frames` + host
  permission) to drive embedded players on third-party pages.
- **LD-11 — Single-file CSV mode.** `showSaveFilePicker` + a persisted `FileSystemFileHandle` to rewrite
  one CSV across sessions (Chrome/Edge/Opera only; Firefox/Safari lack the disk picker).
- **Firefox & Safari build legs** and store/App-Store distribution.
- Optional keyboard shortcuts (capture-phase; must not clobber the player's own j/k/l/space).

## Sources for the verified constraints

The cross-origin-iframe boundary, the no-write-next-to-video sandbox limit, Safari App-Store-only
distribution, `chrome.downloads` overwrite flakiness, and `currentTime` precision were confirmed against
MDN, developer.chrome.com, Mozilla, and Apple developer docs during design research (June 2026).
