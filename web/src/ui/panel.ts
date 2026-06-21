// In-page annotation panel — the browser analogue of the VLC dialog. Rendered into an
// OPEN Shadow DOM so the host page's CSS can't bleed in (and vice-versa) while still
// being reachable by automation/devtools ("closed" is not a real security boundary).
// Every user-facing string goes through the i18n shim t() (keys-not-prose); reason/sport
// VALUES stay canonical (written to the CSV) — only their display labels are translated.

import { Annotator, SPORTS, REASON_OPTIONS, type Msg } from "../state/annotator";
import type { DirectVideoHandler } from "../video/directVideo";
import type { VideoIdentity } from "../persist/store";
import { VERSION } from "../version";
import { t, getLocale, setLocale, SUPPORTED_LOCALES, LOCALE_LABELS, type Locale } from "../i18n";

export interface PanelDeps {
  annotator: Annotator;
  video: DirectVideoHandler;
  identity: VideoIdentity;
  download: (csv: string) => void;
  onLocaleChange?: (locale: Locale) => void; // optional: persist the choice (content script wires this)
}

export interface PanelHandle {
  toggle(): void;
  destroy(): void;
}

// mm:ss.mmm for display (matches the Lua fmt_clock).
function fmtClock(s: number | null): string {
  if (s == null) return "--:--";
  if (s < 0) s = 0;
  const m = Math.floor(s / 60);
  const sec = s - m * 60;
  return `${m}:${sec.toFixed(3).padStart(6, "0")}`;
}

function esc(t: string): string {
  return t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Translate a Msg, mapping canonical reason/sport params to their display labels.
function tMsg(m: Msg): string {
  let p = m.params;
  if (p && (typeof p.reason === "string" || typeof p.sport === "string")) {
    p = { ...p };
    if (typeof p.reason === "string") p.reason = t("reason." + p.reason);
    if (typeof p.sport === "string") p.sport = t("sport." + p.sport);
  }
  return t(m.key, p);
}

const STYLE = `
:host { all: initial; }
* { box-sizing: border-box; font-family: system-ui, "Noto Sans", "Noto Sans Devanagari",
  "Noto Sans Kannada", "Noto Sans Telugu", "Nirmala UI", sans-serif; }
.card {
  position: fixed; top: 16px; right: 16px; width: 340px; z-index: 2147483647;
  background: #1e1f22; color: #e6e6e6; border: 1px solid #444; border-radius: 8px;
  box-shadow: 0 8px 28px rgba(0,0,0,.5); font-size: 12px; user-select: none;
}
.hdr { display: flex; align-items: center; gap: 6px; padding: 7px 9px; cursor: move;
  background: #2b2d31; border-radius: 8px 8px 0 0; }
.hdr .t { font-weight: 600; flex: 1; }
.hdr button { cursor: pointer; }
.body { padding: 9px; display: flex; flex-direction: column; gap: 7px; }
.row { display: flex; gap: 6px; align-items: center; }
.row > * { min-width: 0; }
label { color: #aab; white-space: nowrap; }
input, select, button {
  font-size: 12px; background: #2b2d31; color: #e6e6e6; border: 1px solid #555;
  border-radius: 5px; padding: 4px 6px;
}
input { width: 100%; }
button { cursor: pointer; background: #3a3d44; }
button:hover { background: #474b54; }
button.primary { background: #2f6f4f; border-color: #3c8a63; }
button.primary:hover { background: #38805c; }
.grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 6px; }
.status { background: #15161a; border: 1px solid #333; border-radius: 5px; padding: 6px;
  line-height: 1.45; min-height: 52px; color: #cfd3da; }
.list { background: #15161a; border: 1px solid #333; border-radius: 5px; height: 122px;
  overflow-y: auto; }
.list .item { padding: 3px 6px; cursor: pointer; border-bottom: 1px solid #232427;
  white-space: nowrap; }
.list .item:hover { background: #25262b; }
.list .item.sel { background: #2f4a6f; }
.help { background: #15161a; border: 1px solid #333; border-radius: 5px; padding: 7px;
  line-height: 1.5; max-height: 260px; overflow-y: auto; color: #cfd3da; }
.mini { font-size: 11px; color: #8b90a0; }
`;

function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props: Partial<HTMLElementTagNameMap[K]> & { class?: string } = {},
  ...kids: (Node | string)[]
): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === "class") e.className = v as string;
    else (e as any)[k] = v;
  }
  for (const kid of kids) e.append(kid as any);
  return e;
}

export function mountPanel(deps: PanelDeps): PanelHandle {
  const { annotator: a, video, download } = deps;

  const host = document.createElement("div");
  host.style.all = "initial";
  const root = host.attachShadow({ mode: "open" });
  root.append(h("style", { textContent: STYLE }));

  const card = h("div", { class: "card" });
  root.append(card);

  // ---- header (drag handle) ----
  const titleEl = h("span", { class: "t" });
  const helpBtn = h("button", { title: "Toggle help" });
  const hideBtn = h("button", { textContent: "—", title: "Hide panel" });
  const hdr = h("div", { class: "hdr" }, titleEl, helpBtn, hideBtn);
  card.append(hdr);

  const body = h("div", { class: "body" });
  card.append(body);

  // ---- language ----
  const langLabel = h("label");
  const langSel = h("select", { name: "language" }) as HTMLSelectElement;
  for (const l of SUPPORTED_LOCALES) langSel.append(h("option", { value: l, textContent: LOCALE_LABELS[l] }));
  langSel.value = getLocale();
  body.append(h("div", { class: "row" }, langLabel, langSel));

  // ---- sport ----
  const sportLabel = h("label");
  const sportSel = h("select", { name: "sport" }) as HTMLSelectElement;
  for (const s of SPORTS) sportSel.append(h("option", { value: s }));
  sportSel.value = a.sport;
  body.append(h("div", { class: "row" }, sportLabel, sportSel));

  // ---- playback ----
  const backBtn = h("button");
  const playBtn = h("button");
  const fwdBtn = h("button");
  body.append(h("div", { class: "row" }, backBtn, playBtn, fwdBtn));

  // ---- start / end ----
  const startLabel = h("label");
  const startIn = h("input", { name: "start" }) as HTMLInputElement;
  const endLabel = h("label");
  const endIn = h("input", { name: "end" }) as HTMLInputElement;
  body.append(h("div", { class: "row" }, startLabel, startIn, endLabel, endIn));

  // ---- next # / shots ----
  const nextLabel = h("label");
  const nextIn = h("input", { name: "next" }) as HTMLInputElement;
  const shotsLabel = h("label");
  const shotsIn = h("input", { name: "shots" }) as HTMLInputElement;
  body.append(h("div", { class: "row" }, nextLabel, nextIn, shotsLabel, shotsIn));

  // ---- reason ----
  const reasonLabel = h("label");
  const reasonSel = h("select", { name: "reason" }) as HTMLSelectElement;
  for (const r of REASON_OPTIONS) reasonSel.append(h("option", { value: r }));
  body.append(h("div", { class: "row" }, reasonLabel, reasonSel));

  // ---- mark / save ----
  const markStartBtn = h("button");
  const markEndBtn = h("button");
  const saveBtn = h("button", { class: "primary" });
  body.append(h("div", { class: "grid2" }, markStartBtn, markEndBtn));
  body.append(h("div", { class: "row" }, saveBtn));

  // ---- status ----
  const status = h("div", { class: "status" });
  body.append(status);

  // ---- help (hidden by default) ----
  const help = h("div", { class: "help" });
  help.style.display = "none";
  body.append(help);

  // ---- recent list ----
  const recentLabel = h("div", { class: "mini" });
  body.append(recentLabel);
  const list = h("div", { class: "list" });
  body.append(list);

  // ---- actions ----
  const editBtn = h("button");
  const delBtn = h("button");
  const undoBtn = h("button");
  const refreshBtn = h("button");
  const dlBtn = h("button");
  body.append(h("div", { class: "grid2" }, editBtn, delBtn));
  body.append(h("div", { class: "grid2" }, undoBtn, refreshBtn));
  body.append(h("div", { class: "row" }, dlBtn));

  // ---- state ----
  let selectedN: number | null = null;
  let lastMsg: Msg = { key: "status.ready" };

  function setStatus(m: Msg) {
    lastMsg = m;
    render();
  }

  // Language-only text (static labels, option labels, placeholders, fixed buttons, help).
  // Re-applied on mount and whenever the locale changes.
  function applyI18n() {
    titleEl.textContent = `🏸 ${t("panel.title")} v${VERSION}`;
    langLabel.textContent = t("label.language");
    sportLabel.textContent = t("label.sport");
    for (const o of Array.from(sportSel.options)) o.textContent = t("sport." + o.value);
    backBtn.textContent = t("btn.back5");
    playBtn.textContent = t("btn.playPause");
    fwdBtn.textContent = t("btn.fwd5");
    startLabel.textContent = t("label.start");
    endLabel.textContent = t("label.end");
    nextLabel.textContent = t("label.next");
    shotsLabel.textContent = t("label.shots");
    startIn.placeholder = t("ph.start");
    endIn.placeholder = t("ph.end");
    nextIn.placeholder = t("ph.next");
    shotsIn.placeholder = t("ph.shots");
    reasonLabel.textContent = t("label.reason");
    for (const o of Array.from(reasonSel.options)) o.textContent = t("reason." + o.value);
    editBtn.textContent = t("btn.edit");
    delBtn.textContent = t("btn.delete");
    refreshBtn.textContent = t("btn.refresh");
    dlBtn.textContent = t("btn.downloadCsv");
    recentLabel.textContent = t("label.recent");
    help.innerHTML = t("help.html");
  }

  function render() {
    // fields
    startIn.value = a.startField;
    endIn.value = a.endField;
    nextIn.value = a.nextField;
    shotsIn.value = a.shotsField;
    reasonSel.value = a.reason;
    sportSel.value = a.sport;
    langSel.value = getLocale();
    // state-dependent labels
    markStartBtn.textContent = tMsg(a.markStartLabel());
    markEndBtn.textContent = tMsg(a.markEndLabel());
    saveBtn.textContent = tMsg(a.saveLabel());
    undoBtn.textContent = tMsg(a.undoLabel());
    helpBtn.textContent = help.style.display === "none" ? t("btn.help") : t("btn.hideHelp");
    // status
    const editing = a.mode === "edit" && a.editIndex != null ? a.rows[a.editIndex] : null;
    const last = a.lastRow();
    const lines = [
      tMsg(lastMsg),
      editing ? t("status.modeEdit", { n: editing.n }) : t("status.modeNew"),
    ];
    if (last) {
      lines.push(
        tMsg({
          key: "status.lastRow",
          params: { n: last.n, s: fmtClock(last.s), e: fmtClock(last.e), reason: last.reason },
        })
      );
    }
    lines.push(t("status.footer", { now: fmtClock(video.now()), count: a.rows.length }));
    status.innerHTML =
      lines.map(esc).join("<br>") +
      `<br><span class="mini">${esc(t("status.csvLine", { key: deps.identity.key }))}</span>`;
    // list
    list.replaceChildren();
    for (const r of a.rows) {
      const shotsTxt = r.shots != null ? `  ${r.shots} ${t("ph.shots")}` : "";
      const item = h("div", {
        class: "item" + (r.n === selectedN ? " sel" : ""),
        textContent: `#${r.n}  ${fmtClock(r.s)} → ${fmtClock(r.e)}  [${t("reason." + r.reason)}, ${t("sport." + r.sport)}]${shotsTxt}`,
      });
      item.addEventListener("click", () => {
        selectedN = r.n;
        render();
      });
      list.append(item);
    }
  }

  // ---- wiring ----
  startIn.addEventListener("input", () => {
    a.startField = startIn.value;
    render();
  });
  endIn.addEventListener("input", () => {
    a.endField = endIn.value;
    render();
  });
  nextIn.addEventListener("input", () => {
    a.nextField = nextIn.value;
    render();
  });
  shotsIn.addEventListener("input", () => {
    a.shotsField = shotsIn.value;
  });
  reasonSel.addEventListener("change", () => {
    a.reason = reasonSel.value;
  });
  sportSel.addEventListener("change", () => {
    a.sport = sportSel.value;
  });
  langSel.addEventListener("change", () => {
    setLocale(langSel.value as Locale);
    deps.onLocaleChange?.(getLocale());
    applyI18n();
    render();
  });

  backBtn.addEventListener("click", () =>
    setStatus({ key: video.seekBy(-5) ? "status.seekBack" : "status.noVideoSeek" })
  );
  fwdBtn.addEventListener("click", () =>
    setStatus({ key: video.seekBy(5) ? "status.seekFwd" : "status.noVideoSeek" })
  );
  playBtn.addEventListener("click", () => {
    const st = video.playPause();
    setStatus({ key: st === "playing" ? "status.resumed" : st === "paused" ? "status.paused" : "status.noVideoLoaded" });
  });

  markStartBtn.addEventListener("click", () => setStatus(a.markStart(video.now())));
  markEndBtn.addEventListener("click", () => setStatus(a.markEnd(video.now())));
  saveBtn.addEventListener("click", () => {
    const res = a.saveRally();
    if (res.ok) download(a.toCSV()); // download the full CSV on each save (per design)
    setStatus(res);
  });

  editBtn.addEventListener("click", () => setStatus(a.editSelected(selectedN)));
  delBtn.addEventListener("click", () => {
    const res = a.deleteSelected(selectedN);
    if (res.ok) selectedN = null;
    setStatus(res);
  });
  undoBtn.addEventListener("click", () => setStatus(a.undoLast()));
  refreshBtn.addEventListener("click", () => {
    video.findActive();
    setStatus({ key: video.hasVideo() ? "status.refreshedVideo" : "status.noVideoFound" });
  });
  dlBtn.addEventListener("click", () => {
    download(a.toCSV());
    setStatus({ key: "status.downloaded", params: { count: a.rows.length } });
  });

  helpBtn.addEventListener("click", () => {
    help.style.display = help.style.display === "none" ? "block" : "none";
    render();
  });
  hideBtn.addEventListener("click", () => api.toggle());

  // ---- dragging ----
  let drag: { x: number; y: number; left: number; top: number } | null = null;
  hdr.addEventListener("mousedown", (e) => {
    const rect = card.getBoundingClientRect();
    card.style.right = "auto";
    card.style.left = rect.left + "px";
    card.style.top = rect.top + "px";
    drag = { x: e.clientX, y: e.clientY, left: rect.left, top: rect.top };
    e.preventDefault();
  });
  const onMove = (e: MouseEvent) => {
    if (!drag) return;
    card.style.left = drag.left + (e.clientX - drag.x) + "px";
    card.style.top = drag.top + (e.clientY - drag.y) + "px";
  };
  const onUp = () => {
    drag = null;
  };
  window.addEventListener("mousemove", onMove);
  window.addEventListener("mouseup", onUp);

  // ---- live clock ----
  const clock = window.setInterval(render, 333);

  // ---- fullscreen re-parent (so the panel survives fullscreen video; desktop) ----
  const onFs = () => {
    const fe = document.fullscreenElement;
    if (fe && !fe.contains(host)) fe.append(host);
    else if (!fe && host.parentElement !== document.body) document.body.append(host);
  };
  document.addEventListener("fullscreenchange", onFs);

  document.body.append(host);
  applyI18n();
  render();

  const api: PanelHandle = {
    toggle() {
      host.style.display = host.style.display === "none" ? "" : "none";
    },
    destroy() {
      window.clearInterval(clock);
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      document.removeEventListener("fullscreenchange", onFs);
      host.remove();
    },
  };
  return api;
}
