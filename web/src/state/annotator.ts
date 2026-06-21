// Annotator state machine — a faithful, provider-agnostic port of the pure logic
// in vlc/rally_annotator.lua (the button callbacks + helpers, minus VLC widget I/O).
//
// Localizable by design: operations and button labels return message KEYS + params
// (a `Msg`), never prose — the UI translates them via the i18n shim, so the state
// machine stays pure and i18n-free (keys-not-prose; see docs/LOCALIZATION.md). The
// reason/sport values it stores are canonical English (written verbatim to the CSV);
// only their DISPLAY labels are translated, by the UI.

import { RallyRow, serializeRows } from "./csv";

export const SPORTS = [
  "badminton",
  "tennis",
  "table_tennis",
  "pickleball",
  "padel",
] as const;

export const REASON_DEFAULT = "unknown";
export const REASONS = [
  "winner",
  "forced_error",
  "unforced_error",
  "service_fault",
  "let",
  "other",
] as const;
// Dropdown order: the savable default ("unknown") first so it shows selected.
export const REASON_OPTIONS = [REASON_DEFAULT, ...REASONS] as const;

export type Mode = "new" | "edit";

export interface PersistResult {
  ok: boolean;
  err?: string;
}
export type PersistFn = (rows: RallyRow[]) => PersistResult;

const okPersist: PersistFn = () => ({ ok: true });

// Mirror get_field_num(): strip ALL whitespace (not just ends), "" -> null,
// non-numeric -> null.
function fieldNum(text: string): number | null {
  const t = text.replace(/\s+/g, "");
  if (t === "") return null;
  const v = Number(t);
  return Number.isNaN(v) ? null : v;
}

// A translatable message: a catalog key + optional interpolation params. The UI renders
// it with the i18n shim. `reason`/`sport` params hold canonical values; the UI maps them
// to translated labels at render time (the CSV always keeps the canonical value).
export interface Msg {
  key: string;
  params?: Record<string, string | number>;
}
export interface OpResult extends Msg {
  ok: boolean;
}

export interface AnnotatorOpts {
  rows?: RallyRow[];
  persist?: PersistFn;
}

export class Annotator {
  rows: RallyRow[];
  mode: Mode = "new";
  editIndex: number | null = null;

  // Form fields mirror the editable widgets (kept as strings, like the text inputs).
  startField = "";
  endField = "";
  shotsField = "";
  nextField = "";
  reason: string = REASON_DEFAULT; // non-sticky
  sport: string = SPORTS[0]; // sticky

  private persist: PersistFn;

  constructor(opts: AnnotatorOpts = {}) {
    this.persist = opts.persist ?? okPersist;
    this.rows = opts.rows ?? [];
    this.refreshNextField();
  }

  // ---- pure helpers (ported 1:1) ----

  nextRallyNumber(): number {
    let maxn = 0;
    for (const r of this.rows) if (r.n > maxn) maxn = r.n;
    return maxn + 1;
  }

  indexOfRally(n: number): number {
    return this.rows.findIndex((r) => r.n === n);
  }

  // Smallest integer >= start not already used (auto-advance skips occupied numbers).
  nextFreeFrom(start: number): number {
    let n = start;
    while (this.indexOfRally(n) !== -1) n++;
    return n;
  }

  // The number the next NEW rally will get (the "Next rally #" override, else max+1).
  plannedNextNumber(): number {
    const v = fieldNum(this.nextField);
    if (v != null && v >= 1) return Math.floor(v);
    return this.nextRallyNumber();
  }

  // Optional shots_count: null for blank/negative/non-numeric; else floor. NB: 0 is
  // VALID (the Lua treats only nil/negative as "no count", and 0 is truthy there).
  getShots(): number | null {
    const v = fieldNum(this.shotsField);
    if (v == null || v < 0) return null;
    return Math.floor(v);
  }

  // Fresh rally fully marked (START + END) but not yet saved -> unsaved work exists.
  isArmed(): boolean {
    return (
      this.mode === "new" &&
      fieldNum(this.startField) != null &&
      fieldNum(this.endField) != null
    );
  }

  refreshNextField(): void {
    this.nextField = String(this.nextRallyNumber());
  }

  lastRow(): RallyRow | null {
    return this.rows.length ? this.rows[this.rows.length - 1] : null;
  }

  private editedRally(): RallyRow | null {
    return this.mode === "edit" && this.editIndex != null ? (this.rows[this.editIndex] ?? null) : null;
  }

  // ---- button labels (port of refresh_buttons) -> translatable Msg ----

  saveLabel(): Msg {
    const r = this.editedRally();
    if (r) return { key: "btn.saveChangesN", params: { n: r.n } };
    const s = fieldNum(this.startField);
    const e = fieldNum(this.endField);
    if (s != null && e != null) return { key: "btn.saveRallyN", params: { n: this.plannedNextNumber() } };
    return { key: "btn.saveRally" };
  }

  markStartLabel(): Msg {
    const r = this.editedRally();
    return r ? { key: "btn.reMarkStart", params: { n: r.n } } : { key: "btn.markStart" };
  }

  markEndLabel(): Msg {
    const r = this.editedRally();
    return r ? { key: "btn.reMarkEnd", params: { n: r.n } } : { key: "btn.markEnd" };
  }

  undoLabel(): Msg {
    if (this.mode === "edit") return { key: "btn.undoCancelEdit" };
    const s = fieldNum(this.startField);
    const e = fieldNum(this.endField);
    if (s != null || e != null) return { key: "btn.undoClearMark" };
    const last = this.lastRow();
    if (last) return { key: "btn.undoN", params: { n: last.n } };
    return { key: "btn.undo" };
  }

  // ---- form reset: reason + shots are NON-STICKY; sport & nextField untouched ----
  resetForm(): void {
    this.mode = "new";
    this.editIndex = null;
    this.startField = "";
    this.endField = "";
    this.shotsField = "";
    this.reason = REASON_DEFAULT;
  }

  // ---- operations (port of the button callbacks) -> translatable OpResult ----

  markStart(now: number | null): OpResult {
    if (now == null) return { ok: false, key: "status.noMediaStart" };
    if (this.isArmed()) return { ok: false, key: "status.unsavedGuard" };
    this.startField = now.toFixed(3);
    return { ok: true, key: "status.startSet", params: { t: now.toFixed(3) } };
  }

  markEnd(now: number | null): OpResult {
    if (now == null) return { ok: false, key: "status.noMediaEnd" };
    this.endField = now.toFixed(3);
    return { ok: true, key: "status.endSet", params: { t: now.toFixed(3) } };
  }

  saveRally(): OpResult {
    let s = fieldNum(this.startField);
    let e = fieldNum(this.endField);
    if (s == null) return { ok: false, key: "status.needStart" };
    if (e == null) return { ok: false, key: "status.needEnd" };
    if (e < s) {
      const t = s;
      s = e;
      e = t;
    } // tolerate reversed marks
    if (e <= s) return { ok: false, key: "status.zeroLength" };

    const reason = this.reason || REASON_DEFAULT;
    const sport = this.sport || SPORTS[0];
    const shotsNum = this.getShots();
    const shots = shotsNum != null ? String(shotsNum) : null;

    if (this.mode === "edit" && this.editIndex != null && this.rows[this.editIndex]) {
      const r = this.rows[this.editIndex];
      const backup = { ...r };
      r.s = s;
      r.e = e;
      r.reason = reason;
      r.sport = sport;
      r.shots = shots;
      const res = this.persist(this.rows);
      if (!res.ok) {
        Object.assign(r, backup);
        return { ok: false, key: "status.writeFailed", params: { err: String(res.err) } };
      }
      const params = { n: r.n, s: s.toFixed(3), e: e.toFixed(3), reason, sport };
      this.resetForm();
      return { ok: true, key: "status.updated", params };
    }

    const n = this.plannedNextNumber();
    if (this.indexOfRally(n) !== -1) return { ok: false, key: "status.duplicate", params: { n } };
    const row: RallyRow = { n, s, e, reason, sport, shots, extra: null };
    this.rows.push(row);
    const res = this.persist(this.rows);
    if (!res.ok) {
      this.rows.pop();
      return { ok: false, key: "status.writeFailed", params: { err: String(res.err) } };
    }
    this.nextField = String(this.nextFreeFrom(n + 1));
    const params = { n, s: s.toFixed(3), e: e.toFixed(3), reason, sport };
    this.resetForm();
    return { ok: true, key: "status.saved", params };
  }

  editSelected(n: number | null): OpResult {
    if (this.isArmed()) return { ok: false, key: "status.editGuard" };
    if (n == null) return { ok: false, key: "status.needSelectEdit" };
    const idx = this.indexOfRally(n);
    if (idx === -1) return { ok: false, key: "status.notFound", params: { n } };
    const r = this.rows[idx];
    this.mode = "edit";
    this.editIndex = idx;
    this.startField = r.s.toFixed(3);
    this.endField = r.e.toFixed(3);
    this.shotsField = r.shots != null ? r.shots : "";
    this.reason = r.reason || REASON_DEFAULT;
    this.sport = r.sport || this.sport;
    return { ok: true, key: "status.editing", params: { n: r.n } };
  }

  deleteSelected(n: number | null): OpResult {
    if (n == null) return { ok: false, key: "status.needSelectDelete" };
    const idx = this.indexOfRally(n);
    if (idx === -1) return { ok: false, key: "status.notFound", params: { n } };
    const removed = this.rows.splice(idx, 1)[0];
    const res = this.persist(this.rows);
    if (!res.ok) {
      this.rows.splice(idx, 0, removed);
      return { ok: false, key: "status.writeFailed", params: { err: String(res.err) } };
    }
    this.resetForm();
    this.refreshNextField();
    return { ok: true, key: "status.deleted", params: { n, count: this.rows.length } };
  }

  // 3-way: cancel edit / clear in-progress mark / drop the last committed row.
  undoLast(): OpResult {
    if (this.mode === "edit") {
      this.resetForm();
      return { ok: true, key: "status.editCancelled" };
    }
    const s = fieldNum(this.startField);
    const e = fieldNum(this.endField);
    if (s != null || e != null) {
      this.resetForm();
      return { ok: true, key: "status.clearedMark" };
    }
    if (this.rows.length === 0) return { ok: false, key: "status.nothingUndo" };
    const last = this.rows.pop()!;
    const res = this.persist(this.rows);
    if (!res.ok) {
      this.rows.push(last);
      return { ok: false, key: "status.writeFailed", params: { err: String(res.err) } };
    }
    this.refreshNextField();
    return { ok: true, key: "status.removedLast", params: { n: last.n, count: this.rows.length } };
  }

  toCSV(): string {
    return serializeRows(this.rows);
  }
}
