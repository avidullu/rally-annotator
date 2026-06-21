# Contributing to Rally Annotator

Part of **[Khelsutra](https://khelsutra.guru)** — _“Every rally, indexed. The dead time, gone.”_
This is the open labeling tool of the Khelsutra stack; the rally CSVs it produces are ground truth for
the rally-segmentation pipeline. Because that data matters, **every change is gated by tests** — which is
also what lets us accept and merge outside PRs with confidence.

Issues and PRs are welcome: live test reports per sport/OS, browser-extension features, UX fixes, docs.

## Repository layout

| Path | What | Language / tests |
|---|---|---|
| `vlc/rally_annotator.lua` | The VLC 3.x plugin (local-file labeling) | Lua 5.1 · `test/dialog_test.lua` |
| `web/` | The browser extension (web video, incl. YouTube) | TypeScript (WXT MV3) · Vitest + Playwright |
| `docs/` | Shared contract: CSV format + ending-reason guide | — |

Read [web/DESIGN.md](web/DESIGN.md) (locked decisions) and [web/TESTING.md](web/TESTING.md) before
changing the extension's architecture or test strategy.

## The merge bar (what every PR must satisfy)

A PR is mergeable when **CI is green** and any user-visible change is covered by a test. Concretely:

### Web extension (`web/`)
```bash
cd web
npm install
npm run typecheck   # tsc --noEmit, must be clean
npm run coverage    # unit + jsdom; ENFORCED thresholds (≥95% stmts/lines/funcs, ≥82% branches)
npm run build       # wxt build must succeed
npm run e2e         # Playwright loads the built extension in real Chromium (records a screencast)
```
All four must pass locally; CI (`.github/workflows/web-ci.yml`) runs them on every change under `web/`
and uploads the E2E **screencast** + coverage as artifacts.

**Localization (i18n):** when touching localized UI, every locale catalog must define exactly the `en`
key set (**key-parity**) and no user-facing literal may bypass `t()` (**no-bare-strings**) — both are
merge-blocking. See [docs/LOCALIZATION.md](docs/LOCALIZATION.md) for the locale set, catalog format, and
the AI-draft → native-review process.

### VLC plugin (`vlc/`)
```bash
luac5.1 -p vlc/rally_annotator.lua   # syntax check (the scan-time error class that breaks loading)
lua5.1  test/dialog_test.lua         # headless dialog suite; exit 0 = pass
```
CI (`.github/workflows/ci.yml`) runs both. See [test/README.md](test/README.md) for the Lua setup.

## Adding a feature — the test you must add

We practice **proof-and-validation-driven** development: write the test that proves the behavior, then
make it pass. Don't add behavior that nothing checks.

- **Web — pure logic** (state machine, CSV, identity): add a Vitest case in `web/test/`. The state
  machine is intentionally browser-free and should stay near 100% covered. If you change the CSV, keep
  the **byte-compatibility** round-trip test green (the pipeline depends on it).
- **Web — UI / panel**: drive it through the open shadow root in `web/test/panel.smoke.test.ts`
  (query controls, dispatch events, assert state + DOM). Keep coverage above the thresholds.
- **Web — a new user flow** (e.g. a new control, a new provider): extend `web/e2e/extension.spec.ts`
  so the **real extension** is exercised end-to-end in Chromium. UI/flow changes should not merge on
  unit tests alone.
- **VLC dialog logic**: add a case to `test/dialog_test.lua`; if you move/resize/rename a widget,
  regenerate the layout snapshot with `lua5.1 test/dialog_test.lua --update` and commit it.

If a change is **architectural**, add a decision entry to [web/DESIGN.md](web/DESIGN.md) in the same PR.

## Conventions

- Match the surrounding code's style, naming, and comment density — don't reformat unrelated lines.
- Keep the **CSV schema** stable; new columns go at the end and must round-trip (older CSVs still load).
- Keep the pure state machine free of browser/DOM/`chrome.*` APIs (that's what makes it testable).
- Don't commit build output or browser binaries (`web/.gitignore` covers `.output/`, `node_modules/`,
  `e2e-results/`, `coverage/`).

## PR process

1. Branch from `main`; make the change **and its test(s)**.
2. Run the relevant suite(s) above locally until green.
3. Open a PR (the template's checklist will prompt you). CI must pass.
4. A maintainer reviews and squash-merges.

## License

By contributing you agree your contributions are licensed under the repository's [MIT License](LICENSE).
