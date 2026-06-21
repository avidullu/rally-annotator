// i18n — a dependency-free t() shim over a shared common.json catalog, mirroring
// Khelsutra's marketing-site shim (avidullu/khelsutra `site/public/i18n.js`). Keys, never
// prose; always fall back to `en`; a missing key degrades to en, then to the raw key
// (which the "every used key exists in en" test forbids in practice).
//
// rally-annotator's UI strings are deliberately PLURAL-FREE (counts are phrased neutrally,
// e.g. "Rallies: {count}"), so the shim is interpolation-only — no Intl.PluralRules and
// none of Spanish's 3-form-plural wrinkle. See docs/LOCALIZATION.md.

import en from "./locales/en/common.json";
import kn from "./locales/kn/common.json";
import hi from "./locales/hi/common.json";
import te from "./locales/te/common.json";
import es from "./locales/es/common.json";
import da from "./locales/da/common.json";
import id from "./locales/id/common.json";

export const SUPPORTED_LOCALES = ["en", "kn", "hi", "es", "da", "id", "te"] as const;
export type Locale = (typeof SUPPORTED_LOCALES)[number];
export const DEFAULT_LOCALE: Locale = "en";

// Native-script display names for the language selector.
export const LOCALE_LABELS: Record<Locale, string> = {
  en: "English",
  kn: "ಕನ್ನಡ",
  hi: "हिन्दी",
  es: "Español",
  da: "Dansk",
  id: "Bahasa Indonesia",
  te: "తెలుగు",
};

// Scripts that need a bundled OFL Noto font (Latin locales render with the system stack).
export const NON_LATIN: ReadonlySet<Locale> = new Set<Locale>(["kn", "hi", "te"]);

type Catalog = Record<string, string>;

// Registered catalogs. `en` is the source of truth; the six translated catalogs are
// machine drafts pending native review (see each file's _meta). An unregistered locale,
// or any key missing from a catalog, falls back to en.
const C = (j: unknown) => j as unknown as Catalog;
const CATALOGS: Partial<Record<Locale, Catalog>> = {
  en: C(en),
  kn: C(kn),
  hi: C(hi),
  te: C(te),
  es: C(es),
  da: C(da),
  id: C(id),
};

export function registerCatalog(locale: Locale, catalog: Catalog): void {
  CATALOGS[locale] = catalog;
}

let current: Locale = DEFAULT_LOCALE;
export function getLocale(): Locale {
  return current;
}
export function setLocale(locale: Locale): void {
  current = (SUPPORTED_LOCALES as readonly string[]).includes(locale) ? locale : DEFAULT_LOCALE;
}

function toSupported(code?: string | null): Locale | null {
  if (!code) return null;
  const base = code.toLowerCase().split("-")[0];
  return (SUPPORTED_LOCALES as readonly string[]).includes(base) ? (base as Locale) : null;
}

// Negotiation order (shared with Khelsutra): a stored/explicit preference wins, then the
// browser's languages, then `en`. Pure — safe to call with no arguments outside a browser.
export function negotiateLocale(stored?: string | null, navLangs: readonly string[] = []): Locale {
  const fromStored = toSupported(stored);
  if (fromStored) return fromStored;
  for (const l of navLangs) {
    const m = toSupported(l);
    if (m) return m;
  }
  return DEFAULT_LOCALE;
}

function interpolate(tpl: string, vars?: Record<string, string | number>): string {
  if (!vars) return tpl;
  return tpl.replace(/\{(\w+)\}/g, (_m, k: string) => (k in vars ? String(vars[k]) : `{${k}}`));
}

// t(key, vars?, locale?) — resolve against the locale, then en, then the raw key.
export function t(
  key: string,
  vars?: Record<string, string | number>,
  locale: Locale = current
): string {
  const tpl = CATALOGS[locale]?.[key] ?? CATALOGS.en?.[key] ?? key;
  return interpolate(tpl, vars);
}

// ---- introspection used by the key-parity / key-presence tests ----
export function registeredLocales(): Locale[] {
  return Object.keys(CATALOGS) as Locale[];
}
// Catalog keys excluding the `_meta` bookkeeping entry.
export function catalogKeys(locale: Locale): string[] {
  return Object.keys(CATALOGS[locale] ?? {}).filter((k) => k !== "_meta");
}
export const EN_KEYS: string[] = catalogKeys("en");
