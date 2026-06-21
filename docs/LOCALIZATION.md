# Localization (i18n) — design & locked decisions

> Part of **[Khelsutra](https://khelsutra.guru)**. rally-annotator localizes its UI into the **same
> languages** and using the **same catalog architecture** as the Khelsutra product
> (`avidullu/khelsutra`, PRs #67/#70) — so a rater labels in their own language, and the two repos
> stay aligned on locales, catalog keys, and conventions.

This records the localization **design** and **locked decisions**. "Locked" = settled; change only via a
new decision entry here in a PR. Both front-ends are in scope: the **browser extension** (`web/`) first,
then the **VLC Lua plugin** (`vlc/`).

## Why
rally-annotator is Khelsutra's open labeling tool. Khelsutra ships a localized product (en/kn/hi +
es/da/id, with Telugu requested in khelsutra#72); the labeling tool should meet raters in the same
languages. We mirror Khelsutra's proven i18n foundation rather than invent one.

## Locked decisions

### LD-i1 — Locale set: `en, kn, hi, es, da, id, te`
Khelsutra's shipped six (en, kn, hi, es, da, id) **+ Telugu (te)**. `en` is the source of truth; a
missing key/locale **always falls back to `en`**, never a raw key. (Telugu in Khelsutra: khelsutra#72.)

### LD-i2 — Scope: both front-ends, web first
Browser extension first (it matches Khelsutra's web surface), then the VLC plugin with a **parallel
keyed string table using the same keys**.

### LD-i3 — Shared `common.json` catalog, keys-not-prose
Mirror Khelsutra's catalog: namespaced keys (`panel.*`, `reason.*`, `status.*`, `help.*`, `lang.*`),
**keys not literals**. ICU-lite interpolation + plurals (`Intl.PluralRules` on web; minimal `%{var}`
in Lua). Reuse Khelsutra key names where they overlap.

### LD-i4 — DATA stays canonical English (pipeline invariant)
The reason/sport enum **values** (`winner`, `badminton`, …) and the **CSV header** are DATA written to
the CSV and **never translate**, regardless of UI language — preserving byte-compatible output for the
pipeline. Only **display labels/help/status** translate. A test asserts the CSV is identical across UI
languages.

### LD-i5 — Web runtime: a dependency-free `t()` shim
Mirror Khelsutra's site `public/i18n.js`: a tiny `t(key, vars)` over the shared catalog, ICU-lite
plurals via `Intl.PluralRules`, always-fall-back-to-`en`. Chosen over i18next for the **content-script
overlay** (smallest injected bundle); the catalog format stays identical to the product.

### LD-i6 — Translations: AI draft now, marked pending native review
`en` is authored. The six non-en catalogs are **AI/Gemini drafts, each clearly marked
`"_meta": { "status": "machine-draft", "review": "pending-native" }`**. Native-speaker review is the
quality/launch gate (drafts are inference-only — Khelsutra's standing guardrail). **Spanish (`es`) has a
3-form plural** (`{one, many, other}`) — the one authoring wrinkle; every `es` plural must carry a `many`
arm.

### LD-i7 — Fonts: self-hosted OFL Noto for non-Latin
The web panel self-hosts **OFL Noto** (`@fontsource`, `unicode-range`-scoped) for **Devanagari (hi),
Kannada (kn), Telugu (te)**; es/da/id are Latin (no new font). VLC relies on **system fonts** — Indic/
Telugu rendering in VLC's Qt dialog is a **manual live-test caveat**.

### LD-i8 — Language selection, persisted
Each UI has a language selector. Web: persisted in `chrome.storage.local` (seeded from the browser
language; default `en`). VLC: persisted in a tiny config file (extensions have no settings API).

### LD-i9 — CI gates: key-parity + no-bare-strings (merge-blocking, both front-ends)
**Key-parity**: every locale defines exactly the `en` key set, or CI fails. **No-bare-strings**: no
user-facing literal may bypass `t()`. These keep contributor PRs trustworthy as locales grow.

## Web extension approach (`web/`)
- `web/src/i18n/`: `locales/<lang>/common.json` + the `t()` shim + a store-backed current locale + Noto
  font assets. Catalog namespaces mirror Khelsutra.
- **Refactor:** the pure `Annotator` currently returns English status **strings**; change it to return
  message **keys + params** (e.g. `{ ok, key: "status.savedRally", params: { n, s, e, reason, sport } }`),
  and have the panel render `t(key, params)`. Keeps the state machine pure *and* localizable.
  `SPORTS`/`REASONS` keep canonical values; add `reason.*`/`sport.*` **label** keys for display only.
- `panel.ts`: every label/button/help/status via `t()`; add a language `<select>` (persisted); inject the
  Noto font for the active script into the shadow root.
- **Tests:** key-parity, no-bare-strings, per-locale panel snapshot, **CSV-invariance across languages**,
  and a Playwright E2E that switches each locale and records a **downloadable screencast**.

## VLC plugin approach (`vlc/`)
- `STRINGS[lang][key]` Lua table (same keys as the web catalog; generated from `common.json`), `t(key,
  params)` with `en` fallback + `%{var}` interpolation.
- Language **dropdown**; on change, **rebuild the dialog** (reuse the existing widget-recreation pattern).
  Persist the choice in a config file.
- `descriptor()` stays English (scan sandbox; VLC shows one title); dialog content localizes. Reason/sport
  CSV **values** stay canonical.
- **Tests:** extend `test/dialog_test.lua` — key-parity (every `STRINGS[lang]` == `en` keys), per-language
  label snapshot, CSV-value-canonical. Font rendering = manual VLC live-test.

## Translation process
Author `en` from the extracted strings; AI-draft `hi/kn/es/da/id/te` (each marked machine-draft → pending
native review); track native review separately (the launch gate). The long **ending-reason guide** is the
largest block — phase it after the UI strings.

## Verification
- **web:** `npm run typecheck`; key-parity + no-bare-strings + per-locale snapshot + CSV-invariance tests;
  `npm run build`; Playwright E2E per locale producing **downloadable screencasts** under
  `web/e2e-results/`.
- **VLC:** `lua5.1 test/dialog_test.lua` green (key-parity + snapshots); manual VLC live-test for font
  rendering per script.

## Phasing (PRs)
1. **docs** (this file).
2. **web i18n infra** — `t()` shim + `en` catalog + selector + fonts + CI gates + tests + screencasts
   (English-first proves the architecture, like Khelsutra's site B3).
3. **web translations** — the six AI-drafted catalogs (marked pending review).
4. **VLC i18n** — Lua string table + dropdown + tests; then translations + the localized ending-reason guide.
