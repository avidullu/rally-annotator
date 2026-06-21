import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import {
  t,
  setLocale,
  getLocale,
  negotiateLocale,
  SUPPORTED_LOCALES,
  DEFAULT_LOCALE,
  registeredLocales,
  catalogKeys,
  EN_KEYS,
  LOCALE_LABELS,
} from "../src/i18n";
import { Annotator } from "../src/state/annotator";

describe("t() shim", () => {
  it("interpolates {vars}", () => {
    expect(t("status.removedLast", { n: 7, count: 3 }, "en")).toBe("Removed last rally #7. 3 remaining.");
  });
  it("leaves unknown placeholders intact", () => {
    expect(t("status.startSet", {}, "en")).toContain("{t}");
  });
  it("returns the raw key when missing everywhere", () => {
    expect(t("does.not.exist")).toBe("does.not.exist");
  });
  it("falls back to en for an unregistered locale", () => {
    expect(t("btn.saveRally", undefined, "zz" as never)).toBe("Save Rally");
  });
  it("uses the registered translation for a known locale", () => {
    const hi = t("btn.markStart", undefined, "hi");
    expect(hi.length).toBeGreaterThan(0);
    expect(hi).not.toBe("Mark START"); // actually translated, not an en passthrough
  });
});

describe("locale state + negotiation", () => {
  it("defaults to en", () => {
    expect(DEFAULT_LOCALE).toBe("en");
  });
  it("set/get; an unsupported value falls back to en", () => {
    setLocale("hi");
    expect(getLocale()).toBe("hi");
    setLocale("zz" as never);
    expect(getLocale()).toBe("en");
  });
  it("negotiates stored > navigator > en, normalizing region subtags", () => {
    expect(negotiateLocale("hi")).toBe("hi");
    expect(negotiateLocale(null, ["te-IN", "en"])).toBe("te");
    expect(negotiateLocale("fr", ["pt-BR"])).toBe("en");
    expect(negotiateLocale(null, [])).toBe("en");
  });
});

describe("catalog integrity", () => {
  it("has a display label for every supported locale", () => {
    for (const l of SUPPORTED_LOCALES) expect(LOCALE_LABELS[l]).toBeTruthy();
  });

  it("registers a catalog for every supported locale", () => {
    expect(new Set(registeredLocales())).toEqual(new Set(SUPPORTED_LOCALES));
  });

  it("key-parity: every registered locale defines exactly the en key set", () => {
    const en = new Set(EN_KEYS);
    for (const l of registeredLocales()) {
      const keys = new Set(catalogKeys(l));
      expect([...en].filter((k) => !keys.has(k))).toEqual([]); // none missing
      expect([...keys].filter((k) => !en.has(k))).toEqual([]); // none extra
    }
  });

  it("every key the Annotator can emit exists in the en catalog", () => {
    const en = new Set(EN_KEYS);
    const used = [
      "status.noMediaStart", "status.unsavedGuard", "status.startSet", "status.noMediaEnd",
      "status.endSet", "status.needStart", "status.needEnd", "status.zeroLength", "status.writeFailed",
      "status.updated", "status.duplicate", "status.saved", "status.needSelectEdit", "status.notFound",
      "status.editGuard", "status.editing", "status.needSelectDelete", "status.deleted",
      "status.editCancelled", "status.clearedMark", "status.nothingUndo", "status.removedLast",
      "btn.markStart", "btn.markEnd", "btn.reMarkStart", "btn.reMarkEnd", "btn.saveRally",
      "btn.saveRallyN", "btn.saveChangesN", "btn.undo", "btn.undoCancelEdit", "btn.undoClearMark", "btn.undoN",
    ];
    for (const k of used) expect(en.has(k), `missing en key: ${k}`).toBe(true);
  });
});

describe("CSV output is language-invariant (values are canonical, never translated)", () => {
  function makeCsv(locale: "en" | "hi" | "te") {
    setLocale(locale);
    const a = new Annotator();
    a.markStart(1);
    a.markEnd(2.5);
    a.reason = "winner";
    a.sport = "badminton";
    a.shotsField = "9";
    a.saveRally();
    return a.toCSV();
  }
  it("en / hi / te produce identical CSV with canonical reason+sport", () => {
    const enCsv = makeCsv("en");
    expect(makeCsv("hi")).toBe(enCsv);
    expect(makeCsv("te")).toBe(enCsv);
    expect(enCsv).toContain("1,1.000,2.500,winner,badminton,9");
    setLocale("en");
  });
});

describe("no-bare-strings guard", () => {
  it("panel.ts routes UI text through t() (no bare textContent/placeholder literals)", () => {
    const src = readFileSync(new URL("../src/ui/panel.ts", import.meta.url), "utf8");
    const bare = src.match(/(?:textContent|placeholder)\s*:\s*"[^"]*[A-Za-z][^"]*"/g) ?? [];
    expect(bare).toEqual([]);
  });
});
