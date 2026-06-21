--[[ rally_annotator.lua  --  VLC Lua EXTENSION (v1.6.4)

  Rally Annotator for NET-SEPARATED RACQUET SPORTS
  (badminton · tennis · table tennis · pickleball · padel)

  While watching a match in VLC, mark each rally's START / END and the point-stop
  reason, and append one CSV row per rally. Pause/scrub freely, then click — the
  callback snapshots the exact playback time. Output is a plain CSV that ingests
  directly into common rally-segmentation tooling.

  Output CSV columns (times in decimal SECONDS):
      rally_number,start_time,end_time,ending_reason,sport,shots_count

  WHAT'S NEW IN v1.6.4
    - Guard against silently losing unsaved work: once a rally is fully marked
      (START + END) but not yet saved, clicking Mark START (new rally) or Edit
      selected is REFUSED with a prompt to Save Rally or Undo last first.
    - While editing an existing rally, the Mark buttons relabel to
      "Re-mark START/END (#N)" so it's obvious they change THAT rally, not a new one.

  WHAT'S NEW IN v1.6.3
    - The version now shows next to the plugin name in VLC's "Active Extensions"
      list (Tools > Plugins and extensions), e.g. "Rally Annotator v1.6.3" --
      VLC shows the descriptor title verbatim, so the version is baked into it.

  WHAT'S NEW IN v1.6.2
    - Fix (data safety on resume): if the extension was enabled BEFORE the video
      was loaded, the CSV path fell back to ~/rally_labels.csv and rallies were
      written there instead of next to the video -- so on pause/restart the
      video's labels looked "lost". Now the moment you Mark START (video is
      provably playing), the tool adopts <video>.rallies.csv and loads any
      rallies already saved for it.

  WHAT'S NEW IN v1.6.1
    - Fix: the Recent rallies list now shows EVERY rally (it scrolls), not just
      the most recent 12 -- so the oldest rallies (e.g. #1) are no longer hidden
      and can still be selected for Edit/Delete.

  WHAT'S NEW IN v1.6
    - Playback is now a single PLAY / PAUSE toggle (was separate Play/Resume +
      Pause), so the playback row is just Back 5s / Play / Pause / Fwd 5s.
    - New optional "Number of shots" field -> a shots_count column appended to
      the CSV (blank when you don't fill it; older CSVs still load fine).

  WHAT'S NEW IN v1.3
    - In-dialog HELP button: usage + an ending-reason decision guide, rendered
      inside the extension's own dialog (see "WHERE HELP LIVES" below).
    - Two-step commit: Mark END now ARMS a rally; you pick the (required) reason
      and click "Save Rally" to write it. The reason is RESET after every save,
      so it can never silently reuse the previous rally's reason.
    - Editable Start/End fields (fine-tune the marked seconds before saving).
    - "Recent rallies" list with Edit selected / Delete selected, plus Undo last.

  WHERE HELP LIVES (VLC internals, verified against the 3.0.x source):
    The empty "About <name>.lua" window under Tools > Plugins and extensions >
    Add-ons is VLC's AddonInfoDialog; its body text ("Lua script") is a hardcoded
    constant supplied by VLC's filesystem addon scanner (modules/misc/addons/
    fsstorage.c) and CANNOT be set by an extension. The descriptor() shortdesc/
    description below DO show, but in a different place — the "More information"
    dialog reached from the *Active Extensions* tab. For real, author-controlled
    help we therefore render it INSIDE this extension's dialog (the HELP button).

  WHY a button-dialog (not an auto-pause hook):
    VLC 3.x can expose pause via the {"playing-listener"} capability
    (status_changed/playing_changed), but that callback is flaky on macOS
    (VLC #22778) and the input/meta listeners are broken in VLC 4.0 (#27558).
    A persistent dialog whose button callbacks SNAPSHOT the current playback
    time is portable, precise, and lets the rater pause/scrub before committing.
    So we declare NO listener capabilities.

  UNITS: in VLC 3.x, vlc.var.get(input,"time") is in MICROSECONDS -> /1e6.

  Widget grid args are (col, row, colspan, rowspan), 1-indexed.

  Install (Windows): copy this file to
      %APPDATA%\vlc\lua\extensions\rally_annotator.lua
    macOS:  ~/Library/Application Support/org.videolan.vlc/lua/extensions/
    Linux:  ~/.local/share/vlc/lua/extensions/
  then VLC > Tools > Plugins and extensions > Reload extensions (or restart),
  then enable it from the View menu.

  MIT licensed. https://github.com/avidullu/rally-annotator
]]

--------------------------------------------------------------------------------
-- Extension registration
--------------------------------------------------------------------------------
local VERSION = "1.7.1"

function descriptor()
  return {
    -- VLC's "Active Extensions" list shows the title VERBATIM (it never appends the
    -- version), so we bake the version into the title -- same as VLsub -- to show it
    -- next to the plugin name there. Fed by VERSION so it can't drift. (Concatenation
    -- only: descriptor() runs in VLC's restricted scan sandbox, which has no globals.)
    title       = "Rally Annotator v" .. VERSION,
    version     = VERSION,
    author      = "Avi Dullu",
    url         = "https://github.com/avidullu/rally-annotator",
    shortdesc   = "Mark rally start/end + a point-ending reason to a CSV (net-separated racquet sports)",
    description =
        "Mark each rally's START and END while you watch, tag WHY the point ended "
     .. "(unknown / winner / forced_error / unforced_error / service_fault / let / other), and append "
     .. "one CSV row per rally next to the video "
     .. "(rally_number,start_time,end_time,ending_reason,sport,shots_count; decimal seconds). "
     .. "Built-in Play/Pause + seek so you never leave the window; "
     .. "two-step Save (Mark END, then Save Rally) with a non-sticky reason (defaults to unknown); "
     .. "editable times; edit or delete recent rallies; resumable numbering. "
     .. "For badminton/tennis/table-tennis/pickleball/padel. "
     .. "Click the HELP button inside the dialog for usage + an ending-reason decision guide.",
    capabilities = {}   -- button-click model: no listeners needed
  }
end

--------------------------------------------------------------------------------
-- Config / constants
--------------------------------------------------------------------------------
-- Net-separated racquet sports share a forced/unforced-error point-stop taxonomy.
-- "unknown" is the default/reset value: a real, savable reason meaning "not yet
-- classified" (so a forgotten pick records 'unknown', never the previous rally's reason).
local REASON_DEFAULT = "unknown"
local REASONS = {
  "winner", "forced_error", "unforced_error", "service_fault", "let", "other"
}
local SPORTS = {
  "badminton", "tennis", "table_tennis", "pickleball", "padel"
}
local HEADER = "rally_number,start_time,end_time,ending_reason,sport,shots_count\n"

-- reason/sport -> id lookups. POPULATED IN activate(), NOT here: VLC scans an
-- extension's descriptor() in a restricted Lua sandbox that lacks base globals
-- like ipairs, so calling ipairs at top level makes the whole extension fail to
-- load (it then never appears under the View menu).
local REASON_ID = {}
local SPORT_ID = {}

-- (In-dialog HELP is localized -- it now lives in STRINGS[lang]["help.html"]; see show_help.)

--------------------------------------------------------------------------------
-- i18n -- the dialog CHROME (labels, buttons, reason/sport display, language picker)
-- is localized into en/kn/hi/te/es/da/id. Status messages and the HELP guide stay
-- English for now (the large prose block is a documented later phase; see
-- docs/LOCALIZATION.md). reason/sport DISPLAY labels are localized, but the CSV always
-- stores the CANONICAL English value (mapped from the selected dropdown id), so output
-- stays byte-compatible regardless of interface language.
--
-- STRINGS is GLOBAL (like the callbacks below) so the headless test can assert key-parity.
-- Machine-draft translations, pending native review.
--------------------------------------------------------------------------------
-- AUTO-GENERATED translations (chrome + status + HELP guide). Machine drafts, pending native
-- review (see docs/LOCALIZATION.md). Global (not local) so the headless test can assert key-parity.
-- reason/sport are DISPLAY labels; the CSV stores the canonical English value (via the dropdown id).
STRINGS = {
  ["en"] = {
    ["label.sport"] = "Sport:",
    ["label.start"] = "Start (s):",
    ["label.end"] = "End (s):",
    ["label.next"] = "Next rally #:",
    ["label.shots"] = "Number of shots:",
    ["label.reason"] = "Ending reason:",
    ["label.recent"] = "Recent rallies (select one, then Edit/Delete):",
    ["label.language"] = "Language:",
    ["btn.help"] = "Help",
    ["btn.hideHelp"] = "Hide help",
    ["btn.back5"] = "Back 5s",
    ["btn.playPause"] = "Play / Pause",
    ["btn.fwd5"] = "Fwd 5s",
    ["btn.markStart"] = "Mark START",
    ["btn.markEnd"] = "Mark END",
    ["btn.reMarkStart"] = "Re-mark START (#{n})",
    ["btn.reMarkEnd"] = "Re-mark END (#{n})",
    ["btn.saveRally"] = "Save Rally",
    ["btn.saveRallyN"] = "Save Rally (#{n})",
    ["btn.saveChangesN"] = "Save changes (#{n})",
    ["btn.edit"] = "Edit selected",
    ["btn.delete"] = "Delete selected",
    ["btn.undo"] = "Undo last",
    ["btn.undoCancelEdit"] = "Undo last (cancel edit)",
    ["btn.undoClearMark"] = "Undo last (clear mark)",
    ["btn.undoN"] = "Undo last (#{n})",
    ["btn.refresh"] = "Refresh",
    ["reason.unknown"] = "unknown",
    ["reason.winner"] = "winner",
    ["reason.forced_error"] = "forced error",
    ["reason.unforced_error"] = "unforced error",
    ["reason.service_fault"] = "service fault",
    ["reason.let"] = "let",
    ["reason.other"] = "other",
    ["sport.badminton"] = "badminton",
    ["sport.tennis"] = "tennis",
    ["sport.table_tennis"] = "table tennis",
    ["sport.pickleball"] = "pickleball",
    ["sport.padel"] = "padel",
    ["status.modeEdit"] = "Mode: EDITING rally #{n}  (Save changes to commit, Undo last to cancel).",
    ["status.modeNew"] = "Mode: new rally  (Mark START, Mark END, choose reason, Save Rally).",
    ["status.lastRow"] = "Last row (what Undo removes): #{n}  {start} -> {end}  [{reason}]",
    ["status.footer"] = "Now: {clock}  |  Rallies in CSV: {count}",
    ["status.csvPath"] = "CSV: {path}",
    ["seek.noMedia"] = "No media playing -- cannot seek.",
    ["seek.noTime"] = "No playback time available to seek from.",
    ["seek.done"] = "Seek {delta}s  ->  {clock}.",
    ["markStart.noMedia"] = "No media playing -- cannot mark START.",
    ["markStart.armed"] = "You have an UNSAVED rally (START -> END). Click 'Save Rally' to keep it, or 'Undo last' to clear it, before marking a new START. (You can also edit the Start field by hand.)",
    ["markStart.set"] = "START set @ {clock}. Play to the rally's end, then Mark END.",
    ["markEnd.noMedia"] = "No media playing -- cannot mark END.",
    ["markEnd.set"] = "END set @ {clock}. Choose the Ending reason, then click Save Rally.",
    ["save.needStart"] = "Set a START time first (click Mark START).",
    ["save.needEnd"] = "Set an END time first (click Mark END).",
    ["save.zeroLen"] = "END must be later than START (rally must be > 0s).",
    ["save.writeFailed"] = "WRITE FAILED: {err}",
    ["save.updated"] = "Updated rally #{n}: {start} -> {end}  [{reason}, {sport}{shots}].",
    ["save.duplicate"] = "Rally #{n} already exists -- set \"Next rally #\" to a free number.",
    ["save.saved"] = "Saved rally #{n}: {start} -> {end}  [{reason}, {sport}{shots}].",
    ["edit.armedGuard"] = "Finish the current rally ('Save Rally') or clear it ('Undo last') before editing another -- your unsaved START -> END would be lost.",
    ["edit.needSelect"] = "Pick a rally in the Recent list first, then Edit selected.",
    ["edit.notFound"] = "Rally #{n} not found (try Refresh).",
    ["edit.editing"] = "Editing rally #{n}. Adjust Start/End/reason, then Save changes. (Undo last cancels.)",
    ["del.needSelect"] = "Pick a rally in the Recent list first, then Delete selected.",
    ["del.deleted"] = "Deleted rally #{n}. {count} remaining.",
    ["undo.cancelled"] = "Edit cancelled.",
    ["undo.cleared"] = "Cleared the in-progress START/END (nothing was written).",
    ["undo.nothing"] = "Nothing to undo.",
    ["undo.removed"] = "Removed last rally #{n}. {count} remaining.",
    ["play.paused"] = "Paused. Annotate (or fine-tune Start/End), then Play / Pause to resume.",
    ["play.resumed"] = "Resumed playback.",
    ["play.started"] = "Started playback.",
    ["play.noMedia"] = "No media loaded to play.",
    ["sync.editFirst"] = "Finish (Save changes) or cancel (Undo last) the current edit before refreshing.",
    ["sync.noMedia"] = "No media is playing -- still using this CSV. Open the video, then click Refresh.",
    ["sync.refreshed"] = "Refreshed. {count} rallies loaded for this video.",
    ["sync.switched"] = "Switched to the current video. Loaded {count} existing rallies; next is #{n}.",
    ["activate.fallback"] = "No video detected yet. Open/play the video, then click Mark START -- the tool will switch to that video's own .rallies.csv automatically (and load any rallies already saved for it). Tip: open the video FIRST, then enable this extension.",
    ["activate.resumed"] = "Resumed this video: {count} existing rallies loaded (next is #{n}). Click Help for the guide.",
    ["activate.ready"] = "Ready. Pick the Sport, then mark rallies. Click Help for usage + the ending-reason guide.",
    ["help.html"] = "<b>Rally Annotator &mdash; how to use</b><br>\n<b>Playback:</b> the <b>Back 5s / Play / Pause / Fwd 5s</b> row drives the VLC player from here &mdash; <b>Play / Pause</b> is one toggle (pause, annotate, and resume without switching to the main VLC window).<br>\n1. Pick the <b>Sport</b> (top). It stays set across rallies.<br>\n2. When a rally begins, click <b>Mark START</b> (pause/scrub first for frame accuracy &mdash; it snapshots the current playback time into the Start field).<br>\n3. When the rally ends, click <b>Mark END</b>. You may fine-tune the Start/End seconds by editing those fields directly.<br>\n4. Choose the <b>Ending reason</b> (the box between <b>Mark END</b> and <b>Save Rally</b>; or leave it as <b>unknown</b>), optionally type a <b>Number of shots</b> (the rally's shot/stroke count &mdash; leave blank to skip), then click <b>Save Rally</b> &mdash; one CSV row is written next to the video.<br>\n5. The reason RESETS to <b>unknown</b> after every save (never silently reused), and you can pick the same reason on consecutive rallies.<br>\n6. <b>Recent rallies</b>: select a row, then <b>Edit selected</b> (loads it back into the fields) or <b>Delete selected</b>. <b>Undo last</b> removes the most recent row (the button shows which, e.g. <i>Undo last (#7)</i>), or clears an in-progress mark, or cancels an edit.<br>\n7. <b>Resuming later:</b> labels are saved to the CSV next to the video as you go. Re-open the SAME video and enable the extension &mdash; it reloads your existing rallies and continues numbering. Set the <b>Next rally #</b> field to resume numbering from any value (e.g. restart at 1, or continue from 50); it auto-advances after each save. If you switch videos with this dialog open, click <b>Refresh</b> to load the current video's rallies. (The video's playback position is not restored &mdash; scrub to where you stopped.)<br>\n<br>\n<b>Ending reasons &mdash; what they mean (pick the one that says WHY the rally ended).</b><br>\nAll reasons except <i>winner</i> are charged to the side that LOST the rally.<br>\n&bull; <b>winner</b> &mdash; the last shot landed IN and was not returned (opponent couldn't reach it, or only waved at it). A clean untouched serve (ace) counts here.<br>\n&bull; <b>forced_error</b> &mdash; the loser MISSED (out, or into the net) while UNDER PRESSURE: stretched, rushed, jammed, or handling the opponent's pace/spin/depth. They were made to miss.<br>\n&bull; <b>unforced_error</b> &mdash; the loser MISSED a routine shot they had time AND position to make, with little or no pressure. They gave it away.<br>\n&bull; <b>service_fault</b> &mdash; the point ended on the SERVE: serve into the net, out of the service box, illegal action/foot fault, or a double fault (tennis/padel).<br>\n&bull; <b>let</b> &mdash; the rally is REPLAYED under the rules (no point): e.g. a tennis/table-tennis serve that clips the net and is otherwise good, or outside interference.<br>\n&bull; <b>other</b> &mdash; anything else (occluded footage, injury/retirement, penalty, hindrance). Use sparingly.<br>\n&bull; <b>unknown</b> &mdash; the default; this rally hasn't been classified yet (pick a specific reason when you can).<br>\n<br>\n<b>Quick cases</b><br>\n&bull; Ball/shuttle lands <b>OUT</b> (past the baseline / outside the lines): it is the hitter's miss &mdash; <b>forced</b> if they were under pressure, <b>unforced</b> if it was a comfortable ball. (OUT is NOT automatically forced, and never a winner for the opponent.)<br>\n&bull; <b>Into the net</b> during a rally: same &mdash; forced if pressured, unforced if routine. A <b>serve</b> into the net is <b>service_fault</b>.<br>\n&bull; <b>Net-cord that dribbles over and lands in</b>: live and good &mdash; usually a <b>winner</b> if unreachable, else judge what happens next. On the SERVE it varies by sport: tennis/table-tennis = <b>let</b> (replay); badminton net-tick that passes over and lands in = play on (but a serve shuttle CAUGHT on the net = service_fault); pickleball (2026) = play on.<br>\n&bull; <b>Unsure forced vs unforced?</b> Default to <b>unforced</b> &mdash; only mark forced when you can point to the specific pressure.<br>\n<br>\nOutput: <i>&lt;video&gt;.rallies.csv</i> next to the video. Full guide: docs/ENDING_REASONS.md in the repo.<br>\nClick <b>Hide help</b> to return to the status panel.",
  },
  ["kn"] = {
    ["label.sport"] = "ಕ್ರೀಡೆ:",
    ["label.start"] = "ಆರಂಭ (ಸೆ):",
    ["label.end"] = "ಅಂತ್ಯ (ಸೆ):",
    ["label.next"] = "ಮುಂದಿನ ರ್ಯಾಲಿ #:",
    ["label.shots"] = "ಹೊಡೆತಗಳ ಸಂಖ್ಯೆ:",
    ["label.reason"] = "ಮುಗಿದ ಕಾರಣ:",
    ["label.recent"] = "ಇತ್ತೀಚಿನ ರ್ಯಾಲಿಗಳು (ಒಂದನ್ನು ಆಯ್ಕೆಮಾಡಿ, ನಂತರ ಸಂಪಾದಿಸಿ/ಅಳಿಸಿ):",
    ["label.language"] = "ಭಾಷೆ:",
    ["btn.help"] = "ಸಹಾಯ",
    ["btn.hideHelp"] = "ಸಹಾಯ ಮರೆಮಾಡಿ",
    ["btn.back5"] = "5ಸೆ ಹಿಂದೆ",
    ["btn.playPause"] = "ಪ್ಲೇ / ವಿರಾಮ",
    ["btn.fwd5"] = "5ಸೆ ಮುಂದೆ",
    ["btn.markStart"] = "ಆರಂಭ ಗುರುತಿಸಿ",
    ["btn.markEnd"] = "ಅಂತ್ಯ ಗುರುತಿಸಿ",
    ["btn.reMarkStart"] = "ಆರಂಭ ಮರುಗುರುತಿಸಿ (#{n})",
    ["btn.reMarkEnd"] = "ಅಂತ್ಯ ಮರುಗುರುತಿಸಿ (#{n})",
    ["btn.saveRally"] = "ರ್ಯಾಲಿ ಉಳಿಸಿ",
    ["btn.saveRallyN"] = "ರ್ಯಾಲಿ ಉಳಿಸಿ (#{n})",
    ["btn.saveChangesN"] = "ಬದಲಾವಣೆಗಳನ್ನು ಉಳಿಸಿ (#{n})",
    ["btn.edit"] = "ಆಯ್ದದ್ದನ್ನು ಸಂಪಾದಿಸಿ",
    ["btn.delete"] = "ಆಯ್ದದ್ದನ್ನು ಅಳಿಸಿ",
    ["btn.undo"] = "ಕೊನೆಯದನ್ನು ರದ್ದುಗೊಳಿಸಿ",
    ["btn.undoCancelEdit"] = "ಕೊನೆಯದನ್ನು ರದ್ದುಗೊಳಿಸಿ (ಸಂಪಾದನೆ ರದ್ದು)",
    ["btn.undoClearMark"] = "ಕೊನೆಯದನ್ನು ರದ್ದುಗೊಳಿಸಿ (ಗುರುತು ತೆರವು)",
    ["btn.undoN"] = "ಕೊನೆಯದನ್ನು ರದ್ದುಗೊಳಿಸಿ (#{n})",
    ["btn.refresh"] = "ರಿಫ್ರೆಶ್",
    ["reason.unknown"] = "ಗೊತ್ತಿಲ್ಲ",
    ["reason.winner"] = "ವಿನ್ನರ್",
    ["reason.forced_error"] = "ಒತ್ತಡದ ತಪ್ಪು",
    ["reason.unforced_error"] = "ಸ್ವಯಂ ತಪ್ಪು",
    ["reason.service_fault"] = "ಸರ್ವಿಸ್ ಫಾಲ್ಟ್",
    ["reason.let"] = "ಲೆಟ್",
    ["reason.other"] = "ಇತರೆ",
    ["sport.badminton"] = "ಬ್ಯಾಡ್ಮಿಂಟನ್",
    ["sport.tennis"] = "ಟೆನಿಸ್",
    ["sport.table_tennis"] = "ಟೇಬಲ್ ಟೆನಿಸ್",
    ["sport.pickleball"] = "ಪಿಕಲ್‌ಬಾಲ್",
    ["sport.padel"] = "ಪ್ಯಾಡೆಲ್",
    ["status.modeEdit"] = "ಮೋಡ್: ರ್ಯಾಲಿ #{n} ಸಂಪಾದಿಸುತ್ತಿದೆ  (ಕಮಿಟ್ ಮಾಡಲು ಬದಲಾವಣೆಗಳನ್ನು ಉಳಿಸಿ, ರದ್ದುಗೊಳಿಸಲು ಕೊನೆಯದನ್ನು ರದ್ದುಗೊಳಿಸಿ).",
    ["status.modeNew"] = "ಮೋಡ್: ಹೊಸ ರ್ಯಾಲಿ  (ಆರಂಭ ಗುರುತಿಸಿ, ಅಂತ್ಯ ಗುರುತಿಸಿ, ಕಾರಣ ಆಯ್ಕೆಮಾಡಿ, ರ್ಯಾಲಿ ಉಳಿಸಿ).",
    ["status.lastRow"] = "ಕೊನೆಯ ಸಾಲು (ರದ್ದುಗೊಳಿಸುವಿಕೆ ತೆಗೆಯುವುದು): #{n}  {start} -> {end}  [{reason}]",
    ["status.footer"] = "ಈಗ: {clock}  |  CSV ನಲ್ಲಿ ರ್ಯಾಲಿಗಳು: {count}",
    ["status.csvPath"] = "CSV: {path}",
    ["seek.noMedia"] = "ಯಾವುದೇ ಮೀಡಿಯಾ ಪ್ಲೇ ಆಗುತ್ತಿಲ್ಲ -- ಸೀಕ್ ಮಾಡಲಾಗದು.",
    ["seek.noTime"] = "ಸೀಕ್ ಮಾಡಲು ಯಾವುದೇ ಪ್ಲೇಬ್ಯಾಕ್ ಸಮಯ ಲಭ್ಯವಿಲ್ಲ.",
    ["seek.done"] = "ಸೀಕ್ {delta}ಸೆ  ->  {clock}.",
    ["markStart.noMedia"] = "ಯಾವುದೇ ಮೀಡಿಯಾ ಪ್ಲೇ ಆಗುತ್ತಿಲ್ಲ -- ಆರಂಭ ಗುರುತಿಸಲಾಗದು.",
    ["markStart.armed"] = "ನಿಮ್ಮಲ್ಲಿ ಉಳಿಸದ ರ್ಯಾಲಿ ಇದೆ (ಆರಂಭ -> ಅಂತ್ಯ). ಹೊಸ ಆರಂಭ ಗುರುತಿಸುವ ಮುನ್ನ ಅದನ್ನು ಇಡಲು 'ರ್ಯಾಲಿ ಉಳಿಸಿ' ಕ್ಲಿಕ್ ಮಾಡಿ, ಅಥವಾ ತೆರವುಗೊಳಿಸಲು 'ಕೊನೆಯದನ್ನು ರದ್ದುಗೊಳಿಸಿ'. (ಆರಂಭ ಕ್ಷೇತ್ರವನ್ನು ಕೈಯಿಂದಲೂ ಸಂಪಾದಿಸಬಹುದು.)",
    ["markStart.set"] = "ಆರಂಭ @ {clock} ನಲ್ಲಿ ಸೆಟ್ ಆಯಿತು. ರ್ಯಾಲಿಯ ಅಂತ್ಯದವರೆಗೆ ಪ್ಲೇ ಮಾಡಿ, ನಂತರ ಅಂತ್ಯ ಗುರುತಿಸಿ.",
    ["markEnd.noMedia"] = "ಯಾವುದೇ ಮೀಡಿಯಾ ಪ್ಲೇ ಆಗುತ್ತಿಲ್ಲ -- ಅಂತ್ಯ ಗುರುತಿಸಲಾಗದು.",
    ["markEnd.set"] = "ಅಂತ್ಯ @ {clock} ನಲ್ಲಿ ಸೆಟ್ ಆಯಿತು. ಮುಗಿದ ಕಾರಣ ಆಯ್ಕೆಮಾಡಿ, ನಂತರ ರ್ಯಾಲಿ ಉಳಿಸಿ ಕ್ಲಿಕ್ ಮಾಡಿ.",
    ["save.needStart"] = "ಮೊದಲು ಆರಂಭ ಸಮಯ ಸೆಟ್ ಮಾಡಿ (ಆರಂಭ ಗುರುತಿಸಿ ಕ್ಲಿಕ್ ಮಾಡಿ).",
    ["save.needEnd"] = "ಮೊದಲು ಅಂತ್ಯ ಸಮಯ ಸೆಟ್ ಮಾಡಿ (ಅಂತ್ಯ ಗುರುತಿಸಿ ಕ್ಲಿಕ್ ಮಾಡಿ).",
    ["save.zeroLen"] = "ಅಂತ್ಯವು ಆರಂಭಕ್ಕಿಂತ ನಂತರ ಇರಬೇಕು (ರ್ಯಾಲಿ > 0ಸೆ ಇರಬೇಕು).",
    ["save.writeFailed"] = "ಬರೆಯುವಿಕೆ ವಿಫಲವಾಯಿತು: {err}",
    ["save.updated"] = "ರ್ಯಾಲಿ #{n} ಅಪ್‌ಡೇಟ್ ಆಯಿತು: {start} -> {end}  [{reason}, {sport}{shots}].",
    ["save.duplicate"] = "ರ್ಯಾಲಿ #{n} ಈಗಾಗಲೇ ಇದೆ -- \"ಮುಂದಿನ ರ್ಯಾಲಿ #\" ಅನ್ನು ಖಾಲಿ ಸಂಖ್ಯೆಗೆ ಸೆಟ್ ಮಾಡಿ.",
    ["save.saved"] = "ರ್ಯಾಲಿ #{n} ಉಳಿಸಲಾಯಿತು: {start} -> {end}  [{reason}, {sport}{shots}].",
    ["edit.armedGuard"] = "ಮತ್ತೊಂದನ್ನು ಸಂಪಾದಿಸುವ ಮುನ್ನ ಪ್ರಸ್ತುತ ರ್ಯಾಲಿಯನ್ನು ಮುಗಿಸಿ ('ರ್ಯಾಲಿ ಉಳಿಸಿ') ಅಥವಾ ತೆರವುಗೊಳಿಸಿ ('ಕೊನೆಯದನ್ನು ರದ್ದುಗೊಳಿಸಿ') -- ನಿಮ್ಮ ಉಳಿಸದ ಆರಂಭ -> ಅಂತ್ಯ ಕಳೆದುಹೋಗುತ್ತದೆ.",
    ["edit.needSelect"] = "ಮೊದಲು ಇತ್ತೀಚಿನ ಪಟ್ಟಿಯಲ್ಲಿ ಒಂದು ರ್ಯಾಲಿ ಆಯ್ಕೆಮಾಡಿ, ನಂತರ ಆಯ್ದದ್ದನ್ನು ಸಂಪಾದಿಸಿ.",
    ["edit.notFound"] = "ರ್ಯಾಲಿ #{n} ಸಿಗಲಿಲ್ಲ (ರಿಫ್ರೆಶ್ ಪ್ರಯತ್ನಿಸಿ).",
    ["edit.editing"] = "ರ್ಯಾಲಿ #{n} ಸಂಪಾದಿಸುತ್ತಿದೆ. ಆರಂಭ/ಅಂತ್ಯ/ಕಾರಣ ಸರಿಹೊಂದಿಸಿ, ನಂತರ ಬದಲಾವಣೆಗಳನ್ನು ಉಳಿಸಿ. (ಕೊನೆಯದನ್ನು ರದ್ದುಗೊಳಿಸಿ ರದ್ದು ಮಾಡುತ್ತದೆ.)",
    ["del.needSelect"] = "ಮೊದಲು ಇತ್ತೀಚಿನ ಪಟ್ಟಿಯಲ್ಲಿ ಒಂದು ರ್ಯಾಲಿ ಆಯ್ಕೆಮಾಡಿ, ನಂತರ ಆಯ್ದದ್ದನ್ನು ಅಳಿಸಿ.",
    ["del.deleted"] = "ರ್ಯಾಲಿ #{n} ಅಳಿಸಲಾಯಿತು. {count} ಉಳಿದಿವೆ.",
    ["undo.cancelled"] = "ಸಂಪಾದನೆ ರದ್ದಾಯಿತು.",
    ["undo.cleared"] = "ಪ್ರಗತಿಯಲ್ಲಿರುವ ಆರಂಭ/ಅಂತ್ಯ ತೆರವಾಯಿತು (ಏನೂ ಬರೆಯಲಾಗಲಿಲ್ಲ).",
    ["undo.nothing"] = "ರದ್ದುಗೊಳಿಸಲು ಏನೂ ಇಲ್ಲ.",
    ["undo.removed"] = "ಕೊನೆಯ ರ್ಯಾಲಿ #{n} ತೆಗೆಯಲಾಯಿತು. {count} ಉಳಿದಿವೆ.",
    ["play.paused"] = "ವಿರಾಮಗೊಂಡಿದೆ. ಟಿಪ್ಪಣಿ ಮಾಡಿ (ಅಥವಾ ಆರಂಭ/ಅಂತ್ಯ ಸೂಕ್ಷ್ಮ ಹೊಂದಿಸಿ), ನಂತರ ಮುಂದುವರಿಸಲು ಪ್ಲೇ / ವಿರಾಮ.",
    ["play.resumed"] = "ಪ್ಲೇಬ್ಯಾಕ್ ಮುಂದುವರಿಯಿತು.",
    ["play.started"] = "ಪ್ಲೇಬ್ಯಾಕ್ ಆರಂಭವಾಯಿತು.",
    ["play.noMedia"] = "ಪ್ಲೇ ಮಾಡಲು ಯಾವುದೇ ಮೀಡಿಯಾ ಲೋಡ್ ಆಗಿಲ್ಲ.",
    ["sync.editFirst"] = "ರಿಫ್ರೆಶ್ ಮಾಡುವ ಮುನ್ನ ಪ್ರಸ್ತುತ ಸಂಪಾದನೆಯನ್ನು ಮುಗಿಸಿ (ಬದಲಾವಣೆಗಳನ್ನು ಉಳಿಸಿ) ಅಥವಾ ರದ್ದು ಮಾಡಿ (ಕೊನೆಯದನ್ನು ರದ್ದುಗೊಳಿಸಿ).",
    ["sync.noMedia"] = "ಯಾವುದೇ ಮೀಡಿಯಾ ಪ್ಲೇ ಆಗುತ್ತಿಲ್ಲ -- ಇನ್ನೂ ಈ CSV ಬಳಸುತ್ತಿದೆ. ವೀಡಿಯೋ ತೆರೆಯಿರಿ, ನಂತರ ರಿಫ್ರೆಶ್ ಕ್ಲಿಕ್ ಮಾಡಿ.",
    ["sync.refreshed"] = "ರಿಫ್ರೆಶ್ ಆಯಿತು. ಈ ವೀಡಿಯೋಗಾಗಿ {count} ರ್ಯಾಲಿಗಳು ಲೋಡ್ ಆದವು.",
    ["sync.switched"] = "ಪ್ರಸ್ತುತ ವೀಡಿಯೋಗೆ ಬದಲಾಯಿತು. {count} ಅಸ್ತಿತ್ವದ ರ್ಯಾಲಿಗಳು ಲೋಡ್ ಆದವು; ಮುಂದಿನದು #{n}.",
    ["activate.fallback"] = "ಇನ್ನೂ ಯಾವುದೇ ವೀಡಿಯೋ ಪತ್ತೆಯಾಗಿಲ್ಲ. ವೀಡಿಯೋ ತೆರೆಯಿರಿ/ಪ್ಲೇ ಮಾಡಿ, ನಂತರ ಆರಂಭ ಗುರುತಿಸಿ ಕ್ಲಿಕ್ ಮಾಡಿ -- ಸಾಧನವು ಆ ವೀಡಿಯೋದ ಸ್ವಂತ .rallies.csv ಗೆ ಸ್ವಯಂಚಾಲಿತವಾಗಿ ಬದಲಾಗುತ್ತದೆ (ಮತ್ತು ಅದಕ್ಕಾಗಿ ಈಗಾಗಲೇ ಉಳಿಸಿದ ಯಾವುದೇ ರ್ಯಾಲಿಗಳನ್ನು ಲೋಡ್ ಮಾಡುತ್ತದೆ). ಸಲಹೆ: ಮೊದಲು ವೀಡಿಯೋ ತೆರೆಯಿರಿ, ನಂತರ ಈ ವಿಸ್ತರಣೆ ಸಕ್ರಿಯಗೊಳಿಸಿ.",
    ["activate.resumed"] = "ಈ ವೀಡಿಯೋ ಮುಂದುವರಿಯಿತು: {count} ಅಸ್ತಿತ್ವದ ರ್ಯಾಲಿಗಳು ಲೋಡ್ ಆದವು (ಮುಂದಿನದು #{n}). ಮಾರ್ಗದರ್ಶಿಗಾಗಿ ಸಹಾಯ ಕ್ಲಿಕ್ ಮಾಡಿ.",
    ["activate.ready"] = "ಸಿದ್ಧ. ಕ್ರೀಡೆ ಆಯ್ಕೆಮಾಡಿ, ನಂತರ ರ್ಯಾಲಿಗಳನ್ನು ಗುರುತಿಸಿ. ಬಳಕೆ + ಮುಗಿದ-ಕಾರಣ ಮಾರ್ಗದರ್ಶಿಗಾಗಿ ಸಹಾಯ ಕ್ಲಿಕ್ ಮಾಡಿ.",
    ["help.html"] = "<b>Rally Annotator &mdash; ಬಳಸುವುದು ಹೇಗೆ</b><br>\n<b>ಪ್ಲೇಬ್ಯಾಕ್:</b> <b>5ಸೆ ಹಿಂದೆ / ಪ್ಲೇ / ವಿರಾಮ / 5ಸೆ ಮುಂದೆ</b> ಸಾಲು VLC ಪ್ಲೇಯರ್ ಅನ್ನು ಇಲ್ಲಿಂದಲೇ ನಡೆಸುತ್ತದೆ &mdash; <b>ಪ್ಲೇ / ವಿರಾಮ</b> ಒಂದೇ ಟಾಗಲ್ (ಮುಖ್ಯ VLC ವಿಂಡೋಗೆ ಬದಲಾಯಿಸದೆ ವಿರಾಮಗೊಳಿಸಿ, ಟಿಪ್ಪಣಿ ಹಾಕಿ, ಮತ್ತೆ ಮುಂದುವರಿಸಿ).<br>\n1. <b>ಕ್ರೀಡೆ</b> ಅನ್ನು ಆಯ್ಕೆಮಾಡಿ (ಮೇಲ್ಭಾಗ). ಇದು ರ‍್ಯಾಲಿಗಳಾದ್ಯಂತ ಹಾಗೆಯೇ ಉಳಿಯುತ್ತದೆ.<br>\n2. ರ‍್ಯಾಲಿ ಪ್ರಾರಂಭವಾದಾಗ, <b>ಪ್ರಾರಂಭ ಗುರುತಿಸಿ</b> ಒತ್ತಿ (ಫ್ರೇಮ್ ನಿಖರತೆಗಾಗಿ ಮೊದಲು ವಿರಾಮಗೊಳಿಸಿ/ಸ್ಕ್ರಬ್ ಮಾಡಿ &mdash; ಇದು ಪ್ರಸ್ತುತ ಪ್ಲೇಬ್ಯಾಕ್ ಸಮಯವನ್ನು ಪ್ರಾರಂಭ ಕ್ಷೇತ್ರಕ್ಕೆ ಸ್ನ್ಯಾಪ್‌ಶಾಟ್ ಮಾಡುತ್ತದೆ).<br>\n3. ರ‍್ಯಾಲಿ ಮುಗಿದಾಗ, <b>ಅಂತ್ಯ ಗುರುತಿಸಿ</b> ಒತ್ತಿ. ಆ ಕ್ಷೇತ್ರಗಳನ್ನು ನೇರವಾಗಿ ಸಂಪಾದಿಸುವ ಮೂಲಕ ನೀವು ಪ್ರಾರಂಭ/ಅಂತ್ಯ ಸೆಕೆಂಡುಗಳನ್ನು ಸೂಕ್ಷ್ಮವಾಗಿ ಹೊಂದಿಸಬಹುದು.<br>\n4. <b>ಅಂತ್ಯದ ಕಾರಣ</b> ಆಯ್ಕೆಮಾಡಿ (<b>ಅಂತ್ಯ ಗುರುತಿಸಿ</b> ಮತ್ತು <b>ರ‍್ಯಾಲಿ ಉಳಿಸಿ</b> ನಡುವಿನ ಪೆಟ್ಟಿಗೆ; ಅಥವಾ ಅದನ್ನು <b>unknown</b> ಆಗಿಯೇ ಬಿಡಿ), ಐಚ್ಛಿಕವಾಗಿ <b>ಹೊಡೆತಗಳ ಸಂಖ್ಯೆ</b> ಟೈಪ್ ಮಾಡಿ (ರ‍್ಯಾಲಿಯ ಹೊಡೆತ/ಸ್ಟ್ರೋಕ್ ಎಣಿಕೆ &mdash; ಬಿಟ್ಟುಬಿಡಲು ಖಾಲಿ ಬಿಡಿ), ನಂತರ <b>ರ‍್ಯಾಲಿ ಉಳಿಸಿ</b> ಒತ್ತಿ &mdash; ವೀಡಿಯೋದ ಪಕ್ಕದಲ್ಲಿ ಒಂದು CSV ಸಾಲು ಬರೆಯಲ್ಪಡುತ್ತದೆ.<br>\n5. ಪ್ರತಿ ಉಳಿಸುವಿಕೆಯ ನಂತರ ಕಾರಣವು <b>unknown</b> ಗೆ ಮರುಹೊಂದಿಸಲ್ಪಡುತ್ತದೆ (ಎಂದಿಗೂ ಮೌನವಾಗಿ ಮರುಬಳಕೆಯಾಗುವುದಿಲ್ಲ), ಮತ್ತು ಸತತ ರ‍್ಯಾಲಿಗಳಲ್ಲಿ ನೀವು ಅದೇ ಕಾರಣವನ್ನು ಆಯ್ಕೆಮಾಡಬಹುದು.<br>\n6. <b>ಇತ್ತೀಚಿನ ರ‍್ಯಾಲಿಗಳು</b>: ಒಂದು ಸಾಲನ್ನು ಆಯ್ಕೆಮಾಡಿ, ನಂತರ <b>ಆಯ್ದದ್ದನ್ನು ಸಂಪಾದಿಸಿ</b> (ಅದನ್ನು ಕ್ಷೇತ್ರಗಳಿಗೆ ಮರಳಿ ಲೋಡ್ ಮಾಡುತ್ತದೆ) ಅಥವಾ <b>ಆಯ್ದದ್ದನ್ನು ಅಳಿಸಿ</b>. <b>ಕೊನೆಯದನ್ನು ರದ್ದುಮಾಡಿ</b> ಅತ್ಯಂತ ಇತ್ತೀಚಿನ ಸಾಲನ್ನು ತೆಗೆದುಹಾಕುತ್ತದೆ (ಬಟನ್ ಯಾವುದನ್ನು ತೋರಿಸುತ್ತದೆ, ಉದಾ. <i>ಕೊನೆಯದನ್ನು ರದ್ದುಮಾಡಿ (#7)</i>), ಅಥವಾ ಪ್ರಗತಿಯಲ್ಲಿರುವ ಗುರುತನ್ನು ತೆರವುಗೊಳಿಸುತ್ತದೆ, ಅಥವಾ ಸಂಪಾದನೆಯನ್ನು ರದ್ದುಗೊಳಿಸುತ್ತದೆ.<br>\n7. <b>ನಂತರ ಮುಂದುವರಿಸುವುದು:</b> ನೀವು ಮುಂದುವರಿದಂತೆ ಲೇಬಲ್‌ಗಳು ವೀಡಿಯೋದ ಪಕ್ಕದಲ್ಲಿನ CSV ಗೆ ಉಳಿಸಲ್ಪಡುತ್ತವೆ. ಅದೇ ವೀಡಿಯೋವನ್ನು ಮತ್ತೆ ತೆರೆದು ಎಕ್ಸ್‌ಟೆನ್ಶನ್ ಅನ್ನು ಸಕ್ರಿಯಗೊಳಿಸಿ &mdash; ಇದು ನಿಮ್ಮ ಅಸ್ತಿತ್ವದಲ್ಲಿರುವ ರ‍್ಯಾಲಿಗಳನ್ನು ಮರುಲೋಡ್ ಮಾಡುತ್ತದೆ ಮತ್ತು ಸಂಖ್ಯೆ ಮುಂದುವರಿಸುತ್ತದೆ. ಯಾವುದೇ ಮೌಲ್ಯದಿಂದ ಸಂಖ್ಯೆಯನ್ನು ಮುಂದುವರಿಸಲು <b>ಮುಂದಿನ ರ‍್ಯಾಲಿ #</b> ಕ್ಷೇತ್ರವನ್ನು ಹೊಂದಿಸಿ (ಉದಾ. 1ರಿಂದ ಮರುಪ್ರಾರಂಭಿಸಿ, ಅಥವಾ 50ರಿಂದ ಮುಂದುವರಿಸಿ); ಪ್ರತಿ ಉಳಿಸುವಿಕೆಯ ನಂತರ ಇದು ಸ್ವಯಂಚಾಲಿತವಾಗಿ ಮುಂದುವರಿಯುತ್ತದೆ. ಈ ಡೈಲಾಗ್ ತೆರೆದಿರುವಾಗ ನೀವು ವೀಡಿಯೋಗಳನ್ನು ಬದಲಾಯಿಸಿದರೆ, ಪ್ರಸ್ತುತ ವೀಡಿಯೋದ ರ‍್ಯಾಲಿಗಳನ್ನು ಲೋಡ್ ಮಾಡಲು <b>ರಿಫ್ರೆಶ್</b> ಒತ್ತಿ. (ವೀಡಿಯೋದ ಪ್ಲೇಬ್ಯಾಕ್ ಸ್ಥಾನವನ್ನು ಮರುಸ್ಥಾಪಿಸಲಾಗುವುದಿಲ್ಲ &mdash; ನೀವು ನಿಲ್ಲಿಸಿದಲ್ಲಿಗೆ ಸ್ಕ್ರಬ್ ಮಾಡಿ.)<br>\n<br>\n<b>ಅಂತ್ಯದ ಕಾರಣಗಳು &mdash; ಅವುಗಳ ಅರ್ಥವೇನು (ರ‍್ಯಾಲಿ ಏಕೆ ಮುಗಿಯಿತು ಎಂದು ಹೇಳುವದನ್ನು ಆಯ್ಕೆಮಾಡಿ).</b><br>\n<i>winner</i> ಹೊರತುಪಡಿಸಿ ಎಲ್ಲಾ ಕಾರಣಗಳನ್ನು ರ‍್ಯಾಲಿ ಸೋತ ಭಾಗಕ್ಕೆ ಹೊರಿಸಲಾಗುತ್ತದೆ.<br>\n&bull; <b>winner</b> &mdash; ಕೊನೆಯ ಹೊಡೆತವು ಒಳಗೆ ಬಿದ್ದು ಹಿಂದಿರುಗಿಸಲ್ಪಡಲಿಲ್ಲ (ಎದುರಾಳಿ ಅದನ್ನು ತಲುಪಲಾಗಲಿಲ್ಲ, ಅಥವಾ ಅದರ ಕಡೆ ಕೈಬೀಸಿದರಷ್ಟೆ). ಸ್ಪಷ್ಟವಾದ, ಮುಟ್ಟದ ಸರ್ವ್ (ಏಸ್) ಇಲ್ಲಿ ಎಣಿಕೆಯಾಗುತ್ತದೆ.<br>\n&bull; <b>forced_error</b> &mdash; ಸೋತವರು ಒತ್ತಡದಲ್ಲಿರುವಾಗ ತಪ್ಪಿಸಿಕೊಂಡರು (ಹೊರಗೆ, ಅಥವಾ ನೆಟ್‌ಗೆ): ಎಳೆದಾಡಿ, ಆತುರಪಟ್ಟು, ಒತ್ತರಿಸಲ್ಪಟ್ಟು, ಅಥವಾ ಎದುರಾಳಿಯ ವೇಗ/ಸ್ಪಿನ್/ಆಳವನ್ನು ನಿಭಾಯಿಸುತ್ತಾ. ಅವರನ್ನು ತಪ್ಪಿಸುವಂತೆ ಮಾಡಲಾಯಿತು.<br>\n&bull; <b>unforced_error</b> &mdash; ಸೋತವರು ಮಾಡಲು ಸಮಯ ಮತ್ತು ಸ್ಥಾನ ಎರಡೂ ಇದ್ದ ಸಾಮಾನ್ಯ ಹೊಡೆತವನ್ನು, ಕಡಿಮೆ ಅಥವಾ ಯಾವುದೇ ಒತ್ತಡವಿಲ್ಲದೆ ತಪ್ಪಿಸಿಕೊಂಡರು. ಅವರೇ ಅದನ್ನು ಕೊಟ್ಟುಬಿಟ್ಟರು.<br>\n&bull; <b>service_fault</b> &mdash; ಪಾಯಿಂಟ್ ಸರ್ವ್‌ನಲ್ಲಿ ಮುಗಿಯಿತು: ನೆಟ್‌ಗೆ ಸರ್ವ್, ಸರ್ವಿಸ್ ಬಾಕ್ಸ್‌ನಿಂದ ಹೊರಗೆ, ಅಕ್ರಮ ಕ್ರಿಯೆ/ಫೂಟ್ ಫಾಲ್ಟ್, ಅಥವಾ ಡಬಲ್ ಫಾಲ್ಟ್ (ಟೆನಿಸ್/ಪ್ಯಾಡೆಲ್).<br>\n&bull; <b>let</b> &mdash; ನಿಯಮಗಳ ಪ್ರಕಾರ ರ‍್ಯಾಲಿಯನ್ನು ಮತ್ತೆ ಆಡಲಾಗುತ್ತದೆ (ಪಾಯಿಂಟ್ ಇಲ್ಲ): ಉದಾ. ನೆಟ್ ಅನ್ನು ತಾಗಿ ಇಲ್ಲದಿದ್ದರೆ ಒಳ್ಳೆಯದಾಗಿರುವ ಟೆನಿಸ್/ಟೇಬಲ್-ಟೆನಿಸ್ ಸರ್ವ್, ಅಥವಾ ಹೊರಗಿನ ಹಸ್ತಕ್ಷೇಪ.<br>\n&bull; <b>other</b> &mdash; ಇನ್ನೇನಾದರೂ (ಮುಚ್ಚಿಹೋದ ಫೂಟೇಜ್, ಗಾಯ/ನಿವೃತ್ತಿ, ದಂಡ, ಅಡಚಣೆ). ಮಿತವಾಗಿ ಬಳಸಿ.<br>\n&bull; <b>unknown</b> &mdash; ಡೀಫಾಲ್ಟ್; ಈ ರ‍್ಯಾಲಿ ಇನ್ನೂ ವರ್ಗೀಕರಿಸಲ್ಪಟ್ಟಿಲ್ಲ (ಸಾಧ್ಯವಾದಾಗ ನಿರ್ದಿಷ್ಟ ಕಾರಣವನ್ನು ಆಯ್ಕೆಮಾಡಿ).<br>\n<br>\n<b>ತ್ವರಿತ ಪ್ರಕರಣಗಳು</b><br>\n&bull; ಬಾಲ್/ಶಟಲ್ <b>ಹೊರಗೆ</b> ಬೀಳುತ್ತದೆ (ಬೇಸ್‌ಲೈನ್ ದಾಟಿ / ಗೆರೆಗಳ ಹೊರಗೆ): ಇದು ಹೊಡೆದವರ ತಪ್ಪು &mdash; ಅವರು ಒತ್ತಡದಲ್ಲಿದ್ದರೆ <b>forced</b>, ಅದು ಆರಾಮದಾಯಕ ಬಾಲ್ ಆಗಿದ್ದರೆ <b>unforced</b>. (ಹೊರಗೆ ಎಂಬುದು ಸ್ವಯಂಚಾಲಿತವಾಗಿ forced ಅಲ್ಲ, ಮತ್ತು ಎದುರಾಳಿಗೆ ಎಂದಿಗೂ winner ಅಲ್ಲ.)<br>\n&bull; ರ‍್ಯಾಲಿಯ ಸಮಯದಲ್ಲಿ <b>ನೆಟ್‌ಗೆ</b>: ಅದೇ &mdash; ಒತ್ತಡದಲ್ಲಿದ್ದರೆ forced, ಸಾಮಾನ್ಯವಾಗಿದ್ದರೆ unforced. ನೆಟ್‌ಗೆ ಬಿದ್ದ <b>ಸರ್ವ್</b> <b>service_fault</b>.<br>\n&bull; <b>ನೆಟ್-ಕಾರ್ಡ್ ಅನ್ನು ತಾಗಿ ಮೇಲೆ ತೊಟ್ಟಿಕ್ಕಿ ಒಳಗೆ ಬೀಳುತ್ತದೆ</b>: ಜೀವಂತ ಮತ್ತು ಒಳ್ಳೆಯದು &mdash; ತಲುಪಲಾಗದಿದ್ದರೆ ಸಾಮಾನ್ಯವಾಗಿ <b>winner</b>, ಇಲ್ಲದಿದ್ದರೆ ಮುಂದೇನಾಗುತ್ತದೆ ಎಂದು ತೀರ್ಮಾನಿಸಿ. ಸರ್ವ್‌ನಲ್ಲಿ ಇದು ಕ್ರೀಡೆಗನುಸಾರ ಬದಲಾಗುತ್ತದೆ: ಟೆನಿಸ್/ಟೇಬಲ್-ಟೆನಿಸ್ = <b>let</b> (ಮತ್ತೆ ಆಡಿ); ನೆಟ್ ತಾಗಿ ಮೇಲೆ ದಾಟಿ ಒಳಗೆ ಬೀಳುವ ಬ್ಯಾಡ್ಮಿಂಟನ್ ಸರ್ವ್ = ಆಟ ಮುಂದುವರಿಸಿ (ಆದರೆ ನೆಟ್‌ನಲ್ಲಿ ಸಿಕ್ಕಿಕೊಂಡ ಸರ್ವ್ ಶಟಲ್ = service_fault); ಪಿಕಲ್‌ಬಾಲ್ (2026) = ಆಟ ಮುಂದುವರಿಸಿ.<br>\n&bull; <b>forced ಮತ್ತು unforced ನಡುವೆ ಖಚಿತವಿಲ್ಲವೇ?</b> ಡೀಫಾಲ್ಟ್ ಆಗಿ <b>unforced</b> ಆಯ್ಕೆಮಾಡಿ &mdash; ನಿರ್ದಿಷ್ಟ ಒತ್ತಡವನ್ನು ತೋರಿಸಲು ಸಾಧ್ಯವಾದಾಗ ಮಾತ್ರ forced ಎಂದು ಗುರುತಿಸಿ.<br>\n<br>\nಔಟ್‌ಪುಟ್: ವೀಡಿಯೋದ ಪಕ್ಕದಲ್ಲಿ <i>&lt;video&gt;.rallies.csv</i>. ಪೂರ್ಣ ಮಾರ್ಗದರ್ಶಿ: ರೆಪೋದಲ್ಲಿ docs/ENDING_REASONS.md.<br>\nಸ್ಥಿತಿ ಫಲಕಕ್ಕೆ ಮರಳಲು <b>ಸಹಾಯ ಮರೆಮಾಡಿ</b> ಒತ್ತಿ.",
  },
  ["hi"] = {
    ["label.sport"] = "खेल:",
    ["label.start"] = "शुरू (से):",
    ["label.end"] = "समाप्त (से):",
    ["label.next"] = "अगली रैली #:",
    ["label.shots"] = "शॉट्स की संख्या:",
    ["label.reason"] = "समाप्ति का कारण:",
    ["label.recent"] = "हाल की रैलियाँ (एक चुनें, फिर संपादित/हटाएँ):",
    ["label.language"] = "भाषा:",
    ["btn.help"] = "मदद",
    ["btn.hideHelp"] = "मदद छिपाएँ",
    ["btn.back5"] = "5सै पीछे",
    ["btn.playPause"] = "चलाएँ / रोकें",
    ["btn.fwd5"] = "5सै आगे",
    ["btn.markStart"] = "शुरू चिह्नित करें",
    ["btn.markEnd"] = "समाप्त चिह्नित करें",
    ["btn.reMarkStart"] = "शुरू फिर चिह्नित करें (#{n})",
    ["btn.reMarkEnd"] = "समाप्त फिर चिह्नित करें (#{n})",
    ["btn.saveRally"] = "रैली सहेजें",
    ["btn.saveRallyN"] = "रैली सहेजें (#{n})",
    ["btn.saveChangesN"] = "बदलाव सहेजें (#{n})",
    ["btn.edit"] = "चयनित संपादित करें",
    ["btn.delete"] = "चयनित हटाएँ",
    ["btn.undo"] = "पिछला पूर्ववत करें",
    ["btn.undoCancelEdit"] = "पिछला पूर्ववत करें (संपादन रद्द)",
    ["btn.undoClearMark"] = "पिछला पूर्ववत करें (चिह्न हटाएँ)",
    ["btn.undoN"] = "पिछला पूर्ववत करें (#{n})",
    ["btn.refresh"] = "ताज़ा करें",
    ["reason.unknown"] = "अज्ञात",
    ["reason.winner"] = "विनर",
    ["reason.forced_error"] = "दबाव में गलती",
    ["reason.unforced_error"] = "बेवजह गलती",
    ["reason.service_fault"] = "सर्विस फॉल्ट",
    ["reason.let"] = "लेट",
    ["reason.other"] = "अन्य",
    ["sport.badminton"] = "बैडमिंटन",
    ["sport.tennis"] = "टेनिस",
    ["sport.table_tennis"] = "टेबल टेनिस",
    ["sport.pickleball"] = "पिकलबॉल",
    ["sport.padel"] = "पैडल",
    ["status.modeEdit"] = "मोड: रैली #{n} संपादित कर रहे हैं  (पुष्टि के लिए बदलाव सहेजें, रद्द के लिए पिछला पूर्ववत करें)।",
    ["status.modeNew"] = "मोड: नई रैली  (शुरू चिह्नित करें, समाप्त चिह्नित करें, कारण चुनें, रैली सहेजें)।",
    ["status.lastRow"] = "अंतिम पंक्ति (जिसे पूर्ववत हटाता है): #{n}  {start} -> {end}  [{reason}]",
    ["status.footer"] = "अभी: {clock}  |  CSV में रैलियाँ: {count}",
    ["status.csvPath"] = "CSV: {path}",
    ["seek.noMedia"] = "कोई मीडिया नहीं चल रहा -- सीक नहीं कर सकते।",
    ["seek.noTime"] = "सीक करने के लिए कोई प्लेबैक समय उपलब्ध नहीं।",
    ["seek.done"] = "सीक {delta}सै  ->  {clock}।",
    ["markStart.noMedia"] = "कोई मीडिया नहीं चल रहा -- शुरू चिह्नित नहीं कर सकते।",
    ["markStart.armed"] = "आपके पास एक बिना सहेजी रैली है (शुरू -> समाप्त)। नई शुरू चिह्नित करने से पहले इसे रखने के लिए 'रैली सहेजें' पर क्लिक करें, या हटाने के लिए 'पिछला पूर्ववत करें'। (आप शुरू फ़ील्ड को हाथ से भी संपादित कर सकते हैं।)",
    ["markStart.set"] = "शुरू सेट @ {clock}। रैली के अंत तक चलाएँ, फिर समाप्त चिह्नित करें।",
    ["markEnd.noMedia"] = "कोई मीडिया नहीं चल रहा -- समाप्त चिह्नित नहीं कर सकते।",
    ["markEnd.set"] = "समाप्त सेट @ {clock}। समाप्ति का कारण चुनें, फिर रैली सहेजें पर क्लिक करें।",
    ["save.needStart"] = "पहले शुरू समय सेट करें (शुरू चिह्नित करें पर क्लिक करें)।",
    ["save.needEnd"] = "पहले समाप्त समय सेट करें (समाप्त चिह्नित करें पर क्लिक करें)।",
    ["save.zeroLen"] = "समाप्त, शुरू से बाद का होना चाहिए (रैली > 0सै होनी चाहिए)।",
    ["save.writeFailed"] = "लिखने में विफल: {err}",
    ["save.updated"] = "रैली #{n} अपडेट हुई: {start} -> {end}  [{reason}, {sport}{shots}]।",
    ["save.duplicate"] = "रैली #{n} पहले से मौजूद है -- \"अगली रैली #\" को किसी खाली नंबर पर सेट करें।",
    ["save.saved"] = "रैली #{n} सहेजी गई: {start} -> {end}  [{reason}, {sport}{shots}]।",
    ["edit.armedGuard"] = "दूसरी रैली संपादित करने से पहले मौजूदा रैली पूरी करें ('रैली सहेजें') या उसे हटाएँ ('पिछला पूर्ववत करें') -- आपकी बिना सहेजी शुरू -> समाप्त खो जाएगी।",
    ["edit.needSelect"] = "पहले हाल की सूची में एक रैली चुनें, फिर चयनित संपादित करें।",
    ["edit.notFound"] = "रैली #{n} नहीं मिली (ताज़ा करें आज़माएँ)।",
    ["edit.editing"] = "रैली #{n} संपादित कर रहे हैं। शुरू/समाप्त/कारण समायोजित करें, फिर बदलाव सहेजें। (पिछला पूर्ववत करें रद्द करता है।)",
    ["del.needSelect"] = "पहले हाल की सूची में एक रैली चुनें, फिर चयनित हटाएँ।",
    ["del.deleted"] = "रैली #{n} हटाई गई। {count} शेष।",
    ["undo.cancelled"] = "संपादन रद्द किया गया।",
    ["undo.cleared"] = "प्रगति में चल रही शुरू/समाप्त हटाई गई (कुछ भी नहीं लिखा गया)।",
    ["undo.nothing"] = "पूर्ववत करने के लिए कुछ नहीं।",
    ["undo.removed"] = "अंतिम रैली #{n} हटाई गई। {count} शेष।",
    ["play.paused"] = "रुका हुआ। एनोटेट करें (या शुरू/समाप्त को बारीकी से सेट करें), फिर जारी रखने के लिए चलाएँ / रोकें।",
    ["play.resumed"] = "प्लेबैक फिर शुरू हुआ।",
    ["play.started"] = "प्लेबैक शुरू हुआ।",
    ["play.noMedia"] = "चलाने के लिए कोई मीडिया लोड नहीं है।",
    ["sync.editFirst"] = "ताज़ा करने से पहले मौजूदा संपादन पूरा करें (बदलाव सहेजें) या रद्द करें (पिछला पूर्ववत करें)।",
    ["sync.noMedia"] = "कोई मीडिया नहीं चल रहा -- अभी भी इसी CSV का उपयोग हो रहा है। वीडियो खोलें, फिर ताज़ा करें पर क्लिक करें।",
    ["sync.refreshed"] = "ताज़ा किया गया। इस वीडियो के लिए {count} रैलियाँ लोड हुईं।",
    ["sync.switched"] = "मौजूदा वीडियो पर स्विच किया गया। {count} मौजूदा रैलियाँ लोड हुईं; अगली #{n} है।",
    ["activate.fallback"] = "अभी तक कोई वीडियो नहीं मिला। वीडियो खोलें/चलाएँ, फिर शुरू चिह्नित करें पर क्लिक करें -- टूल स्वतः उस वीडियो की अपनी .rallies.csv पर स्विच कर जाएगा (और उसके लिए पहले से सहेजी कोई भी रैलियाँ लोड करेगा)। सुझाव: पहले वीडियो खोलें, फिर इस एक्सटेंशन को सक्षम करें।",
    ["activate.resumed"] = "इस वीडियो को फिर शुरू किया: {count} मौजूदा रैलियाँ लोड हुईं (अगली #{n} है)। गाइड के लिए मदद पर क्लिक करें।",
    ["activate.ready"] = "तैयार। खेल चुनें, फिर रैलियाँ चिह्नित करें। उपयोग + समाप्ति-कारण गाइड के लिए मदद पर क्लिक करें।",
    ["help.html"] = "<b>Rally Annotator &mdash; उपयोग कैसे करें</b><br>\n<b>प्लेबैक:</b> <b>5 सेकंड पीछे / चलाएँ / रोकें / 5 सेकंड आगे</b> पंक्ति यहीं से VLC प्लेयर को नियंत्रित करती है &mdash; <b>चलाएँ / रोकें</b> एक ही टॉगल है (मुख्य VLC विंडो पर स्विच किए बिना रोकें, लेबल करें और फिर से चलाएँ)।<br>\n1. <b>खेल</b> (सबसे ऊपर) चुनें। यह सभी रैलियों में सेट रहता है।<br>\n2. जब कोई रैली शुरू हो, तो <b>शुरुआत चिह्नित करें</b> पर क्लिक करें (फ़्रेम-सटीकता के लिए पहले रोकें/स्क्रब करें &mdash; यह वर्तमान प्लेबैक समय को Start फ़ील्ड में सहेज लेता है)।<br>\n3. जब रैली समाप्त हो, तो <b>समाप्ति चिह्नित करें</b> पर क्लिक करें। आप उन फ़ील्ड्स को सीधे संपादित करके Start/End सेकंड को बारीकी से समायोजित कर सकते हैं।<br>\n4. <b>समाप्ति कारण</b> चुनें (<b>समाप्ति चिह्नित करें</b> और <b>रैली सहेजें</b> के बीच वाला बॉक्स; या इसे <b>unknown</b> ही रहने दें), वैकल्पिक रूप से <b>शॉट्स की संख्या</b> टाइप करें (रैली में शॉट/स्ट्रोक की गिनती &mdash; छोड़ने के लिए खाली रखें), फिर <b>रैली सहेजें</b> पर क्लिक करें &mdash; वीडियो के बगल में एक CSV पंक्ति लिखी जाती है।<br>\n5. हर सहेजने के बाद कारण <b>unknown</b> पर रीसेट हो जाता है (कभी भी चुपचाप दोबारा उपयोग नहीं होता), और आप लगातार रैलियों में वही कारण चुन सकते हैं।<br>\n6. <b>हाल की रैलियाँ</b>: एक पंक्ति चुनें, फिर <b>चयनित संपादित करें</b> (इसे वापस फ़ील्ड्स में लोड करता है) या <b>चयनित हटाएँ</b>। <b>अंतिम पूर्ववत करें</b> सबसे हाल की पंक्ति को हटाता है (बटन दिखाता है कि कौन-सी, जैसे <i>अंतिम पूर्ववत करें (#7)</i>), या किसी प्रगति-में चिह्न को साफ़ करता है, या किसी संपादन को रद्द करता है।<br>\n7. <b>बाद में फिर से शुरू करना:</b> जैसे-जैसे आप काम करते हैं, लेबल वीडियो के बगल वाली CSV में सहेजे जाते हैं। उसी वीडियो को फिर से खोलें और एक्सटेंशन सक्षम करें &mdash; यह आपकी मौजूदा रैलियाँ फिर से लोड कर लेता है और क्रमांकन जारी रखता है। किसी भी मान से क्रमांकन फिर से शुरू करने के लिए <b>अगली रैली #</b> फ़ील्ड सेट करें (जैसे 1 से फिर से शुरू करें, या 50 से जारी रखें); यह हर सहेजने के बाद स्वतः आगे बढ़ता है। यदि आप इस संवाद को खुला रखते हुए वीडियो बदलते हैं, तो वर्तमान वीडियो की रैलियाँ लोड करने के लिए <b>ताज़ा करें</b> पर क्लिक करें। (वीडियो की प्लेबैक स्थिति पुनर्स्थापित नहीं होती &mdash; जहाँ आपने रोका था वहाँ स्क्रब करें।)<br>\n<br>\n<b>समाप्ति कारण &mdash; इनका क्या अर्थ है (वह कारण चुनें जो बताता है कि रैली क्यों समाप्त हुई)।</b><br>\n<i>winner</i> को छोड़कर सभी कारण उस पक्ष के खाते में दर्ज होते हैं जो रैली हार गया।<br>\n&bull; <b>winner</b> &mdash; अंतिम शॉट IN गिरा और वापस नहीं लौटाया गया (प्रतिद्वंद्वी उस तक पहुँच नहीं सका, या केवल उसकी ओर हाथ हिलाया)। एक साफ़ बिना-छुआ सर्व (ace) यहीं गिना जाता है।<br>\n&bull; <b>forced_error</b> &mdash; हारने वाला दबाव में रहते हुए चूका (बाहर, या नेट में): खिंचा हुआ, जल्दबाज़ी में, फँसा हुआ, या प्रतिद्वंद्वी की गति/स्पिन/गहराई को संभालते हुए। उसे चूकने पर मजबूर किया गया।<br>\n&bull; <b>unforced_error</b> &mdash; हारने वाले ने एक सामान्य शॉट चूका जिसे खेलने के लिए उसके पास समय और स्थिति दोनों थे, बहुत कम या बिना किसी दबाव के। उसने खुद गलती की।<br>\n&bull; <b>service_fault</b> &mdash; अंक SERVE पर समाप्त हुआ: नेट में सर्व, सर्विस बॉक्स के बाहर, अवैध क्रिया/फुट फ़ॉल्ट, या डबल फ़ॉल्ट (टेनिस/पैडल)।<br>\n&bull; <b>let</b> &mdash; नियमों के अनुसार रैली फिर से खेली जाती है (कोई अंक नहीं): जैसे एक टेनिस/टेबल-टेनिस सर्व जो नेट को छूकर निकले और अन्यथा सही हो, या बाहरी हस्तक्षेप।<br>\n&bull; <b>other</b> &mdash; और कुछ भी (बाधित फ़ुटेज, चोट/संन्यास, पेनल्टी, बाधा)। संयम से उपयोग करें।<br>\n&bull; <b>unknown</b> &mdash; डिफ़ॉल्ट; इस रैली को अभी तक वर्गीकृत नहीं किया गया है (जब संभव हो तब कोई विशिष्ट कारण चुनें)।<br>\n<br>\n<b>त्वरित मामले</b><br>\n&bull; गेंद/शटल <b>OUT</b> गिरती है (बेसलाइन के पार / लाइनों के बाहर): यह मारने वाले की चूक है &mdash; <b>forced</b> यदि वह दबाव में था, <b>unforced</b> यदि वह एक आरामदायक गेंद थी। (OUT स्वतः forced नहीं होता, और प्रतिद्वंद्वी के लिए कभी winner नहीं होता।)<br>\n&bull; रैली के दौरान <b>नेट में</b>: वही &mdash; दबाव में हो तो forced, सामान्य हो तो unforced। नेट में किया गया <b>सर्व</b> <b>service_fault</b> है।<br>\n&bull; <b>नेट-कॉर्ड जो लुढ़ककर पार जाए और अंदर गिरे</b>: जीवित और सही &mdash; आमतौर पर <b>winner</b> यदि अपहुँच हो, अन्यथा आगे जो होता है उससे आँकें। SERVE पर यह खेल के अनुसार बदलता है: टेनिस/टेबल-टेनिस = <b>let</b> (फिर से खेलें); बैडमिंटन नेट-टिक जो ऊपर से पार जाकर अंदर गिरे = खेल जारी (पर नेट पर फँसी सर्व शटल = service_fault); पिकलबॉल (2026) = खेल जारी।<br>\n&bull; <b>forced बनाम unforced को लेकर अनिश्चित?</b> डिफ़ॉल्ट रूप से <b>unforced</b> रखें &mdash; forced तभी चिह्नित करें जब आप विशिष्ट दबाव की ओर इशारा कर सकें।<br>\n<br>\nआउटपुट: वीडियो के बगल में <i>&lt;video&gt;.rallies.csv</i>। पूरी गाइड: रिपॉज़िटरी में docs/ENDING_REASONS.md।<br>\nस्थिति पैनल पर लौटने के लिए <b>सहायता छिपाएँ</b> पर क्लिक करें।",
  },
  ["te"] = {
    ["label.sport"] = "క్రీడ:",
    ["label.start"] = "ప్రారంభం (s):",
    ["label.end"] = "ముగింపు (s):",
    ["label.next"] = "తదుపరి ర్యాలీ #:",
    ["label.shots"] = "షాట్ల సంఖ్య:",
    ["label.reason"] = "ముగింపు కారణం:",
    ["label.recent"] = "ఇటీవలి ర్యాలీలు (ఒకటి ఎంచుకుని, ఆపై సవరించు/తొలగించు):",
    ["label.language"] = "భాష:",
    ["btn.help"] = "సహాయం",
    ["btn.hideHelp"] = "సహాయం దాచు",
    ["btn.back5"] = "వెనక్కి 5s",
    ["btn.playPause"] = "ప్లే / పాజ్",
    ["btn.fwd5"] = "ముందుకు 5s",
    ["btn.markStart"] = "ప్రారంభం గుర్తించు",
    ["btn.markEnd"] = "ముగింపు గుర్తించు",
    ["btn.reMarkStart"] = "ప్రారంభం మళ్లీ గుర్తించు (#{n})",
    ["btn.reMarkEnd"] = "ముగింపు మళ్లీ గుర్తించు (#{n})",
    ["btn.saveRally"] = "ర్యాలీ సేవ్ చేయి",
    ["btn.saveRallyN"] = "ర్యాలీ సేవ్ చేయి (#{n})",
    ["btn.saveChangesN"] = "మార్పులు సేవ్ చేయి (#{n})",
    ["btn.edit"] = "ఎంచుకున్నది సవరించు",
    ["btn.delete"] = "ఎంచుకున్నది తొలగించు",
    ["btn.undo"] = "చివరిది రద్దు చేయి",
    ["btn.undoCancelEdit"] = "చివరిది రద్దు చేయి (సవరణ రద్దు)",
    ["btn.undoClearMark"] = "చివరిది రద్దు చేయి (గుర్తు తొలగించు)",
    ["btn.undoN"] = "చివరిది రద్దు చేయి (#{n})",
    ["btn.refresh"] = "రిఫ్రెష్",
    ["reason.unknown"] = "తెలియదు",
    ["reason.winner"] = "విన్నర్",
    ["reason.forced_error"] = "ఒత్తిడి తప్పు",
    ["reason.unforced_error"] = "సొంత తప్పు",
    ["reason.service_fault"] = "సర్వీస్ ఫాల్ట్",
    ["reason.let"] = "లెట్",
    ["reason.other"] = "ఇతరం",
    ["sport.badminton"] = "బ్యాడ్మింటన్",
    ["sport.tennis"] = "టెన్నిస్",
    ["sport.table_tennis"] = "టేబుల్ టెన్నిస్",
    ["sport.pickleball"] = "పికిల్‌బాల్",
    ["sport.padel"] = "పాడెల్",
    ["status.modeEdit"] = "మోడ్: ర్యాలీ #{n} సవరిస్తోంది  (కమిట్ చేయడానికి మార్పులు సేవ్ చేయి, రద్దు చేయడానికి చివరిది రద్దు చేయి).",
    ["status.modeNew"] = "మోడ్: కొత్త ర్యాలీ  (ప్రారంభం గుర్తించు, ముగింపు గుర్తించు, కారణం ఎంచుకో, ర్యాలీ సేవ్ చేయి).",
    ["status.lastRow"] = "చివరి వరుస (రద్దు ఏది తొలగిస్తుందో): #{n}  {start} -> {end}  [{reason}]",
    ["status.footer"] = "ఇప్పుడు: {clock}  |  CSVలో ర్యాలీలు: {count}",
    ["status.csvPath"] = "CSV: {path}",
    ["seek.noMedia"] = "మీడియా ఏదీ ప్లే కావడం లేదు -- సీక్ చేయలేము.",
    ["seek.noTime"] = "సీక్ చేయడానికి ప్లేబ్యాక్ సమయం అందుబాటులో లేదు.",
    ["seek.done"] = "సీక్ {delta}s  ->  {clock}.",
    ["markStart.noMedia"] = "మీడియా ఏదీ ప్లే కావడం లేదు -- ప్రారంభం గుర్తించలేము.",
    ["markStart.armed"] = "మీకు సేవ్ చేయని ర్యాలీ ఉంది (ప్రారంభం -> ముగింపు). కొత్త ప్రారంభం గుర్తించే ముందు, దాన్ని ఉంచడానికి 'ర్యాలీ సేవ్ చేయి' నొక్కండి, లేదా తొలగించడానికి 'చివరిది రద్దు చేయి' నొక్కండి. (ప్రారంభం ఫీల్డ్‌ను చేతితో కూడా సవరించవచ్చు.)",
    ["markStart.set"] = "ప్రారంభం సెట్ చేయబడింది @ {clock}. ర్యాలీ ముగింపు వరకు ప్లే చేసి, ఆపై ముగింపు గుర్తించు.",
    ["markEnd.noMedia"] = "మీడియా ఏదీ ప్లే కావడం లేదు -- ముగింపు గుర్తించలేము.",
    ["markEnd.set"] = "ముగింపు సెట్ చేయబడింది @ {clock}. ముగింపు కారణం ఎంచుకుని, ఆపై ర్యాలీ సేవ్ చేయి నొక్కండి.",
    ["save.needStart"] = "ముందుగా ప్రారంభ సమయం సెట్ చేయండి (ప్రారంభం గుర్తించు నొక్కండి).",
    ["save.needEnd"] = "ముందుగా ముగింపు సమయం సెట్ చేయండి (ముగింపు గుర్తించు నొక్కండి).",
    ["save.zeroLen"] = "ముగింపు ప్రారంభం కంటే తరువాత ఉండాలి (ర్యాలీ > 0s ఉండాలి).",
    ["save.writeFailed"] = "రాయడం విఫలమైంది: {err}",
    ["save.updated"] = "ర్యాలీ #{n} నవీకరించబడింది: {start} -> {end}  [{reason}, {sport}{shots}].",
    ["save.duplicate"] = "ర్యాలీ #{n} ఇప్పటికే ఉంది -- \"తదుపరి ర్యాలీ #\"ను ఖాళీ సంఖ్యకు సెట్ చేయండి.",
    ["save.saved"] = "ర్యాలీ #{n} సేవ్ చేయబడింది: {start} -> {end}  [{reason}, {sport}{shots}].",
    ["edit.armedGuard"] = "మరొకటి సవరించే ముందు ప్రస్తుత ర్యాలీని పూర్తి చేయండి ('ర్యాలీ సేవ్ చేయి') లేదా తొలగించండి ('చివరిది రద్దు చేయి') -- మీ సేవ్ చేయని ప్రారంభం -> ముగింపు కోల్పోతుంది.",
    ["edit.needSelect"] = "ముందుగా ఇటీవలి జాబితాలో ఒక ర్యాలీని ఎంచుకుని, ఆపై ఎంచుకున్నది సవరించు.",
    ["edit.notFound"] = "ర్యాలీ #{n} కనబడలేదు (రిఫ్రెష్ ప్రయత్నించండి).",
    ["edit.editing"] = "ర్యాలీ #{n} సవరిస్తోంది. ప్రారంభం/ముగింపు/కారణం సర్దుబాటు చేసి, ఆపై మార్పులు సేవ్ చేయి. (చివరిది రద్దు చేయి అది రద్దు చేస్తుంది.)",
    ["del.needSelect"] = "ముందుగా ఇటీవలి జాబితాలో ఒక ర్యాలీని ఎంచుకుని, ఆపై ఎంచుకున్నది తొలగించు.",
    ["del.deleted"] = "ర్యాలీ #{n} తొలగించబడింది. {count} మిగిలి ఉన్నాయి.",
    ["undo.cancelled"] = "సవరణ రద్దు చేయబడింది.",
    ["undo.cleared"] = "ప్రగతిలో ఉన్న ప్రారంభం/ముగింపు తొలగించబడింది (ఏదీ రాయబడలేదు).",
    ["undo.nothing"] = "రద్దు చేయడానికి ఏమీ లేదు.",
    ["undo.removed"] = "చివరి ర్యాలీ #{n} తొలగించబడింది. {count} మిగిలి ఉన్నాయి.",
    ["play.paused"] = "పాజ్ చేయబడింది. ఏనోటేట్ చేయండి (లేదా ప్రారంభం/ముగింపు సర్దుబాటు చేయండి), ఆపై కొనసాగించడానికి ప్లే / పాజ్.",
    ["play.resumed"] = "ప్లేబ్యాక్ కొనసాగించబడింది.",
    ["play.started"] = "ప్లేబ్యాక్ ప్రారంభించబడింది.",
    ["play.noMedia"] = "ప్లే చేయడానికి మీడియా ఏదీ లోడ్ కాలేదు.",
    ["sync.editFirst"] = "రిఫ్రెష్ చేసే ముందు ప్రస్తుత సవరణను పూర్తి చేయండి (మార్పులు సేవ్ చేయి) లేదా రద్దు చేయండి (చివరిది రద్దు చేయి).",
    ["sync.noMedia"] = "మీడియా ఏదీ ప్లే కావడం లేదు -- ఇంకా ఈ CSVను ఉపయోగిస్తోంది. వీడియో తెరిచి, ఆపై రిఫ్రెష్ నొక్కండి.",
    ["sync.refreshed"] = "రిఫ్రెష్ చేయబడింది. ఈ వీడియో కోసం {count} ర్యాలీలు లోడ్ చేయబడ్డాయి.",
    ["sync.switched"] = "ప్రస్తుత వీడియోకు మారబడింది. {count} ఉన్న ర్యాలీలు లోడ్ చేయబడ్డాయి; తదుపరిది #{n}.",
    ["activate.fallback"] = "ఇంకా వీడియో ఏదీ గుర్తించబడలేదు. వీడియో తెరవండి/ప్లే చేయండి, ఆపై ప్రారంభం గుర్తించు నొక్కండి -- సాధనం ఆ వీడియో సొంత .rallies.csvకు స్వయంచాలకంగా మారుతుంది (మరియు దాని కోసం ఇప్పటికే సేవ్ చేసిన ఏ ర్యాలీలనైనా లోడ్ చేస్తుంది). చిట్కా: ముందుగా వీడియో తెరిచి, ఆపై ఈ ఎక్స్‌టెన్షన్‌ను ప్రారంభించండి.",
    ["activate.resumed"] = "ఈ వీడియో కొనసాగించబడింది: {count} ఉన్న ర్యాలీలు లోడ్ చేయబడ్డాయి (తదుపరిది #{n}). గైడ్ కోసం సహాయం నొక్కండి.",
    ["activate.ready"] = "సిద్ధం. క్రీడను ఎంచుకుని, ఆపై ర్యాలీలను గుర్తించండి. వినియోగం + ముగింపు-కారణ గైడ్ కోసం సహాయం నొక్కండి.",
    ["help.html"] = "<b>Rally Annotator &mdash; ఎలా ఉపయోగించాలి</b><br>\n<b>ప్లేబ్యాక్:</b> <b>5 సె. వెనక్కి / ప్లే / పాజ్ / 5 సె. ముందుకు</b> వరుస ఇక్కడి నుండే VLC ప్లేయర్‌ను నడిపిస్తుంది &mdash; <b>ప్లే / పాజ్</b> ఒకే టోగుల్ (ప్రధాన VLC విండోకి మారకుండానే పాజ్ చేసి, లేబుల్ చేసి, తిరిగి కొనసాగించవచ్చు).<br>\n1. <b>క్రీడ</b> (పైన) ఎంచుకోండి. ఇది ర్యాలీల అంతటా అలాగే ఉంటుంది.<br>\n2. ఒక ర్యాలీ మొదలైనప్పుడు <b>మొదలు గుర్తించు</b> క్లిక్ చేయండి (ఫ్రేమ్ ఖచ్చితత్వం కోసం ముందుగా పాజ్ చేయండి/స్క్రబ్ చేయండి &mdash; ఇది ప్రస్తుత ప్లేబ్యాక్ సమయాన్ని Start ఫీల్డ్‌లోకి స్నాప్‌షాట్ చేస్తుంది).<br>\n3. ర్యాలీ ముగిసినప్పుడు <b>ముగింపు గుర్తించు</b> క్లిక్ చేయండి. ఆ ఫీల్డ్‌లను నేరుగా సవరించడం ద్వారా Start/End సెకన్లను మీరు సూక్ష్మంగా సర్దుబాటు చేయవచ్చు.<br>\n4. <b>ముగింపు కారణం</b> ఎంచుకోండి (<b>ముగింపు గుర్తించు</b> మరియు <b>ర్యాలీ సేవ్ చేయి</b> మధ్య ఉన్న బాక్స్; లేదా దానిని <b>unknown</b> గా వదిలేయండి), ఐచ్ఛికంగా <b>షాట్ల సంఖ్య</b> టైప్ చేయండి (ర్యాలీ యొక్క షాట్/స్ట్రోక్ లెక్క &mdash; దాటవేయడానికి ఖాళీగా వదిలేయండి), ఆపై <b>ర్యాలీ సేవ్ చేయి</b> క్లిక్ చేయండి &mdash; వీడియో పక్కన ఒక CSV వరుస వ్రాయబడుతుంది.<br>\n5. ప్రతి సేవ్ తర్వాత కారణం <b>unknown</b> కు రీసెట్ అవుతుంది (ఎప్పుడూ మౌనంగా తిరిగి ఉపయోగించబడదు), మరియు వరుస ర్యాలీలలో మీరు అదే కారణాన్ని ఎంచుకోవచ్చు.<br>\n6. <b>ఇటీవలి ర్యాలీలు</b>: ఒక వరుసను ఎంచుకుని, ఆపై <b>ఎంచుకున్నది సవరించు</b> (దాన్ని తిరిగి ఫీల్డ్‌లలోకి లోడ్ చేస్తుంది) లేదా <b>ఎంచుకున్నది తొలగించు</b>. <b>చివరిది రద్దుచేయి</b> అత్యంత ఇటీవలి వరుసను తీసివేస్తుంది (బటన్ ఏది అనేది చూపిస్తుంది, ఉదా. <i>చివరిది రద్దుచేయి (#7)</i>), లేదా జరుగుతున్న మార్క్‌ను క్లియర్ చేస్తుంది, లేదా సవరణను రద్దు చేస్తుంది.<br>\n7. <b>తర్వాత తిరిగి కొనసాగించడం:</b> మీరు చేస్తున్నప్పుడు లేబుల్‌లు వీడియో పక్కన ఉన్న CSVలో సేవ్ అవుతాయి. అదే వీడియోను మళ్ళీ తెరిచి ఎక్స్‌టెన్షన్‌ను ఎనేబుల్ చేయండి &mdash; ఇది మీ ఇప్పటికే ఉన్న ర్యాలీలను తిరిగి లోడ్ చేసి, నంబరింగ్‌ను కొనసాగిస్తుంది. ఏదైనా విలువ నుండి నంబరింగ్‌ను తిరిగి ప్రారంభించడానికి <b>తదుపరి ర్యాలీ #</b> ఫీల్డ్‌ను సెట్ చేయండి (ఉదా. 1 వద్ద పునఃప్రారంభించండి, లేదా 50 నుండి కొనసాగించండి); ఇది ప్రతి సేవ్ తర్వాత స్వయంచాలకంగా ముందుకు సాగుతుంది. ఈ డైలాగ్ తెరిచి ఉండగా మీరు వీడియోలను మార్చితే, ప్రస్తుత వీడియో యొక్క ర్యాలీలను లోడ్ చేయడానికి <b>రిఫ్రెష్</b> క్లిక్ చేయండి. (వీడియో యొక్క ప్లేబ్యాక్ స్థానం పునరుద్ధరించబడదు &mdash; మీరు ఆపిన చోటికి స్క్రబ్ చేయండి.)<br>\n<br>\n<b>ముగింపు కారణాలు &mdash; వాటి అర్థం ఏమిటి (ర్యాలీ ఎందుకు ముగిసిందో చెప్పేదాన్ని ఎంచుకోండి).</b><br>\n<i>winner</i> తప్ప అన్ని కారణాలు ర్యాలీని ఓడిన పక్షంపై వేయబడతాయి.<br>\n&bull; <b>winner</b> &mdash; చివరి షాట్ లోపల (IN) పడింది మరియు తిరిగి కొట్టబడలేదు (ప్రత్యర్థి దాన్ని చేరుకోలేకపోయాడు, లేదా దానిపై చేతిని ఊపాడంతే). స్పర్శించని శుభ్రమైన సర్వ్ (ఏస్) ఇక్కడ లెక్కించబడుతుంది.<br>\n&bull; <b>forced_error</b> &mdash; ఒత్తిడిలో ఉన్నప్పుడు ఓడినవాడు మిస్ చేశాడు (బయటకు, లేదా నెట్‌లోకి): సాగదీయబడ్డ, తొందరపడ్డ, ఇరుక్కుపోయిన, లేదా ప్రత్యర్థి యొక్క వేగం/స్పిన్/లోతును ఎదుర్కొంటూ. వారిని మిస్ చేసేలా చేశారు.<br>\n&bull; <b>unforced_error</b> &mdash; ఓడినవాడు, దాదాపు ఒత్తిడి లేకుండా, తనకు సమయం మరియు స్థానం రెండూ ఉన్న సాధారణ షాట్‌ను మిస్ చేశాడు. వారు దాన్ని వదిలేశారు.<br>\n&bull; <b>service_fault</b> &mdash; పాయింట్ సర్వ్‌పైనే ముగిసింది: నెట్‌లోకి సర్వ్, సర్వీస్ బాక్స్ బయటకు, చట్టవిరుద్ధమైన చర్య/ఫుట్ ఫాల్ట్, లేదా డబుల్ ఫాల్ట్ (టెన్నిస్/పడెల్).<br>\n&bull; <b>let</b> &mdash; నియమాల ప్రకారం ర్యాలీ మళ్ళీ ఆడబడుతుంది (పాయింట్ లేదు): ఉదా. నెట్‌ను తాకి మిగతా విధంగా మంచిగా ఉన్న టెన్నిస్/టేబుల్-టెన్నిస్ సర్వ్, లేదా బయటి జోక్యం.<br>\n&bull; <b>other</b> &mdash; మిగతా ఏదైనా (కవరైన ఫుటేజ్, గాయం/విరమణ, పెనాల్టీ, అడ్డంకి). పొదుపుగా వాడండి.<br>\n&bull; <b>unknown</b> &mdash; డిఫాల్ట్; ఈ ర్యాలీ ఇంకా వర్గీకరించబడలేదు (మీకు వీలైనప్పుడు నిర్దిష్ట కారణాన్ని ఎంచుకోండి).<br>\n<br>\n<b>త్వరిత సందర్భాలు</b><br>\n&bull; బంతి/షటిల్ <b>బయట</b> పడింది (బేస్‌లైన్ దాటి / గీతల వెలుపల): అది కొట్టినవాడి మిస్ &mdash; వారు ఒత్తిడిలో ఉంటే <b>forced</b>, అది సౌకర్యవంతమైన బంతి అయితే <b>unforced</b>. (బయట పడటం అనేది స్వయంచాలకంగా forced కాదు, మరియు ప్రత్యర్థికి ఎప్పటికీ winner కాదు.)<br>\n&bull; ర్యాలీ సమయంలో <b>నెట్‌లోకి</b>: అదే విధంగా &mdash; ఒత్తిడిలో ఉంటే forced, సాధారణమైతే unforced. నెట్‌లోకి వెళ్ళిన <b>సర్వ్</b> అనేది <b>service_fault</b>.<br>\n&bull; <b>నెట్-కార్డ్ తాకి దాటి లోపల పడటం</b>: సజీవంగా మరియు మంచిది &mdash; చేరుకోలేనట్లయితే సాధారణంగా <b>winner</b>, లేకుంటే తర్వాత ఏమి జరుగుతుందో దాన్ని బట్టి నిర్ణయించండి. సర్వ్‌పై ఇది క్రీడను బట్టి మారుతుంది: టెన్నిస్/టేబుల్-టెన్నిస్ = <b>let</b> (మళ్ళీ ఆడటం); బ్యాడ్మింటన్‌లో నెట్‌ను తాకి దాటి లోపల పడిన షటిల్ = ఆట కొనసాగుతుంది (కానీ నెట్‌పై చిక్కుకున్న సర్వ్ షటిల్ = service_fault); పికిల్‌బాల్ (2026) = ఆట కొనసాగుతుంది.<br>\n&bull; <b>forced vs unforced మధ్య సందేహమా?</b> డిఫాల్ట్‌గా <b>unforced</b> ఎంచుకోండి &mdash; మీరు నిర్దిష్ట ఒత్తిడిని చూపగలిగినప్పుడు మాత్రమే forced గా గుర్తించండి.<br>\n<br>\nఅవుట్‌పుట్: వీడియో పక్కన <i>&lt;video&gt;.rallies.csv</i>. పూర్తి గైడ్: రిపోజిటరీలో docs/ENDING_REASONS.md.<br>\nస్థితి ప్యానెల్‌కు తిరిగి వెళ్ళడానికి <b>సహాయం దాచు</b> క్లిక్ చేయండి.",
  },
  ["es"] = {
    ["label.sport"] = "Deporte:",
    ["label.start"] = "Inicio (s):",
    ["label.end"] = "Fin (s):",
    ["label.next"] = "Próximo rally #:",
    ["label.shots"] = "Número de golpes:",
    ["label.reason"] = "Motivo de cierre:",
    ["label.recent"] = "Rallies recientes (selecciona uno, luego Editar/Eliminar):",
    ["label.language"] = "Idioma:",
    ["btn.help"] = "Ayuda",
    ["btn.hideHelp"] = "Ocultar ayuda",
    ["btn.back5"] = "Atrás 5s",
    ["btn.playPause"] = "Reproducir / Pausar",
    ["btn.fwd5"] = "Adelante 5s",
    ["btn.markStart"] = "Marcar INICIO",
    ["btn.markEnd"] = "Marcar FIN",
    ["btn.reMarkStart"] = "Re-marcar INICIO (#{n})",
    ["btn.reMarkEnd"] = "Re-marcar FIN (#{n})",
    ["btn.saveRally"] = "Guardar rally",
    ["btn.saveRallyN"] = "Guardar rally (#{n})",
    ["btn.saveChangesN"] = "Guardar cambios (#{n})",
    ["btn.edit"] = "Editar seleccionado",
    ["btn.delete"] = "Eliminar seleccionado",
    ["btn.undo"] = "Deshacer último",
    ["btn.undoCancelEdit"] = "Deshacer último (cancelar edición)",
    ["btn.undoClearMark"] = "Deshacer último (borrar marca)",
    ["btn.undoN"] = "Deshacer último (#{n})",
    ["btn.refresh"] = "Actualizar",
    ["reason.unknown"] = "desconocido",
    ["reason.winner"] = "ganador",
    ["reason.forced_error"] = "error forzado",
    ["reason.unforced_error"] = "error no forzado",
    ["reason.service_fault"] = "falta de servicio",
    ["reason.let"] = "let",
    ["reason.other"] = "otro",
    ["sport.badminton"] = "bádminton",
    ["sport.tennis"] = "tenis",
    ["sport.table_tennis"] = "tenis de mesa",
    ["sport.pickleball"] = "pickleball",
    ["sport.padel"] = "pádel",
    ["status.modeEdit"] = "Modo: EDITANDO rally #{n}  (Guardar cambios para confirmar, Deshacer último para cancelar).",
    ["status.modeNew"] = "Modo: rally nuevo  (Marcar INICIO, Marcar FIN, elegir motivo, Guardar rally).",
    ["status.lastRow"] = "Última fila (lo que Deshacer elimina): #{n}  {start} -> {end}  [{reason}]",
    ["status.footer"] = "Ahora: {clock}  |  Rallies en CSV: {count}",
    ["status.csvPath"] = "CSV: {path}",
    ["seek.noMedia"] = "No hay medio reproduciéndose -- no se puede buscar.",
    ["seek.noTime"] = "No hay tiempo de reproducción disponible para buscar.",
    ["seek.done"] = "Buscar {delta}s  ->  {clock}.",
    ["markStart.noMedia"] = "No hay medio reproduciéndose -- no se puede marcar INICIO.",
    ["markStart.armed"] = "Tienes un rally SIN GUARDAR (INICIO -> FIN). Haz clic en 'Guardar rally' para conservarlo, o en 'Deshacer último' para borrarlo, antes de marcar un nuevo INICIO. (También puedes editar el campo Inicio a mano.)",
    ["markStart.set"] = "INICIO fijado @ {clock}. Reproduce hasta el final del rally, luego Marcar FIN.",
    ["markEnd.noMedia"] = "No hay medio reproduciéndose -- no se puede marcar FIN.",
    ["markEnd.set"] = "FIN fijado @ {clock}. Elige el motivo de cierre, luego haz clic en Guardar rally.",
    ["save.needStart"] = "Fija primero un tiempo de INICIO (haz clic en Marcar INICIO).",
    ["save.needEnd"] = "Fija primero un tiempo de FIN (haz clic en Marcar FIN).",
    ["save.zeroLen"] = "El FIN debe ser posterior al INICIO (el rally debe ser > 0s).",
    ["save.writeFailed"] = "ESCRITURA FALLIDA: {err}",
    ["save.updated"] = "Rally #{n} actualizado: {start} -> {end}  [{reason}, {sport}{shots}].",
    ["save.duplicate"] = "El rally #{n} ya existe -- fija \"Próximo rally #\" en un número libre.",
    ["save.saved"] = "Rally #{n} guardado: {start} -> {end}  [{reason}, {sport}{shots}].",
    ["edit.armedGuard"] = "Termina el rally actual ('Guardar rally') o bórralo ('Deshacer último') antes de editar otro -- tu INICIO -> FIN sin guardar se perdería.",
    ["edit.needSelect"] = "Primero elige un rally en la lista Recientes, luego Editar seleccionado.",
    ["edit.notFound"] = "Rally #{n} no encontrado (prueba Actualizar).",
    ["edit.editing"] = "Editando rally #{n}. Ajusta Inicio/Fin/motivo, luego Guardar cambios. (Deshacer último cancela.)",
    ["del.needSelect"] = "Primero elige un rally en la lista Recientes, luego Eliminar seleccionado.",
    ["del.deleted"] = "Rally #{n} eliminado. Quedan {count}.",
    ["undo.cancelled"] = "Edición cancelada.",
    ["undo.cleared"] = "Se borró el INICIO/FIN en progreso (no se escribió nada).",
    ["undo.nothing"] = "Nada que deshacer.",
    ["undo.removed"] = "Se eliminó el último rally #{n}. Quedan {count}.",
    ["play.paused"] = "En pausa. Anota (o ajusta Inicio/Fin), luego Reproducir / Pausar para continuar.",
    ["play.resumed"] = "Reproducción reanudada.",
    ["play.started"] = "Reproducción iniciada.",
    ["play.noMedia"] = "No hay medio cargado para reproducir.",
    ["sync.editFirst"] = "Termina (Guardar cambios) o cancela (Deshacer último) la edición actual antes de actualizar.",
    ["sync.noMedia"] = "No hay medio reproduciéndose -- se sigue usando este CSV. Abre el video, luego haz clic en Actualizar.",
    ["sync.refreshed"] = "Actualizado. {count} rallies cargados para este video.",
    ["sync.switched"] = "Se cambió al video actual. Se cargaron {count} rallies existentes; el próximo es #{n}.",
    ["activate.fallback"] = "Aún no se detecta video. Abre/reproduce el video, luego haz clic en Marcar INICIO -- la herramienta cambiará automáticamente al .rallies.csv propio de ese video (y cargará los rallies ya guardados para él). Consejo: abre el video PRIMERO, luego habilita esta extensión.",
    ["activate.resumed"] = "Video reanudado: se cargaron {count} rallies existentes (el próximo es #{n}). Haz clic en Ayuda para ver la guía.",
    ["activate.ready"] = "Listo. Elige el Deporte, luego marca los rallies. Haz clic en Ayuda para ver el uso + la guía de motivos de cierre.",
    ["help.html"] = "<b>Rally Annotator &mdash; cómo usarlo</b><br>\n<b>Reproducción:</b> la fila <b>Atrás 5s / Reproducir / Pausa / Adelante 5s</b> controla el reproductor de VLC desde aquí &mdash; <b>Reproducir / Pausa</b> es un único conmutador (pausa, anota y reanuda sin cambiar a la ventana principal de VLC).<br>\n1. Elige el <b>Deporte</b> (arriba). Permanece fijo entre rallies.<br>\n2. Cuando empiece un rally, haz clic en <b>Marcar INICIO</b> (pausa o avanza fotograma a fotograma primero para mayor precisión &mdash; captura el tiempo de reproducción actual en el campo Inicio).<br>\n3. Cuando termine el rally, haz clic en <b>Marcar FIN</b>. Puedes ajustar con precisión los segundos de Inicio/Fin editando esos campos directamente.<br>\n4. Elige el <b>Motivo de finalización</b> (la casilla entre <b>Marcar FIN</b> y <b>Guardar rally</b>; o déjala en <b>unknown</b>), opcionalmente escribe un <b>Número de golpes</b> (el recuento de golpes/jugadas del rally &mdash; déjalo en blanco para omitirlo) y luego haz clic en <b>Guardar rally</b> &mdash; se escribe una fila CSV junto al vídeo.<br>\n5. El motivo se REINICIA a <b>unknown</b> después de cada guardado (nunca se reutiliza de forma silenciosa), y puedes elegir el mismo motivo en rallies consecutivos.<br>\n6. <b>Rallies recientes</b>: selecciona una fila y luego <b>Editar seleccionado</b> (la vuelve a cargar en los campos) o <b>Eliminar seleccionado</b>. <b>Deshacer último</b> elimina la fila más reciente (el botón indica cuál, p. ej. <i>Deshacer último (#7)</i>), o borra una marca en curso, o cancela una edición.<br>\n7. <b>Reanudar más tarde:</b> las etiquetas se guardan en el CSV junto al vídeo a medida que avanzas. Vuelve a abrir el MISMO vídeo y activa la extensión &mdash; recarga tus rallies existentes y continúa la numeración. Ajusta el campo <b>Siguiente rally #</b> para reanudar la numeración desde cualquier valor (p. ej. reiniciar en 1, o continuar desde 50); avanza automáticamente después de cada guardado. Si cambias de vídeo con este cuadro de diálogo abierto, haz clic en <b>Actualizar</b> para cargar los rallies del vídeo actual. (La posición de reproducción del vídeo no se restaura &mdash; avanza hasta donde lo dejaste.)<br>\n<br>\n<b>Motivos de finalización &mdash; qué significan (elige el que indica POR QUÉ terminó el rally).</b><br>\nTodos los motivos excepto <i>winner</i> se atribuyen al lado que PERDIÓ el rally.<br>\n&bull; <b>winner</b> &mdash; el último golpe cayó DENTRO y no fue devuelto (el rival no pudo alcanzarlo, o solo lo rozó). Un saque limpio sin tocar (ace) cuenta aquí.<br>\n&bull; <b>forced_error</b> &mdash; el perdedor FALLÓ (fuera, o a la red) estando BAJO PRESIÓN: estirado, apurado, trabado, o lidiando con la velocidad/efecto/profundidad del rival. Lo obligaron a fallar.<br>\n&bull; <b>unforced_error</b> &mdash; el perdedor FALLÓ un golpe rutinario que tenía tiempo Y posición para ejecutar, con poca o ninguna presión. Lo regaló.<br>\n&bull; <b>service_fault</b> &mdash; el punto terminó en el SAQUE: saque a la red, fuera del cuadro de servicio, acción ilegal/falta de pie, o doble falta (tenis/pádel).<br>\n&bull; <b>let</b> &mdash; el rally se REPITE según las reglas (sin punto): p. ej. un saque de tenis/tenis de mesa que roza la red y por lo demás es bueno, o una interferencia externa.<br>\n&bull; <b>other</b> &mdash; cualquier otra cosa (imagen obstruida, lesión/retirada, sanción, estorbo). Úsalo con moderación.<br>\n&bull; <b>unknown</b> &mdash; el valor por defecto; este rally aún no se ha clasificado (elige un motivo específico cuando puedas).<br>\n<br>\n<b>Casos rápidos</b><br>\n&bull; La pelota/volante cae <b>FUERA</b> (más allá de la línea de fondo / fuera de las líneas): es el fallo del que golpea &mdash; <b>forced</b> si estaba bajo presión, <b>unforced</b> si era una bola cómoda. (FUERA NO es automáticamente forced, ni nunca un winner para el rival.)<br>\n&bull; <b>A la red</b> durante un rally: lo mismo &mdash; forced si hubo presión, unforced si era rutinario. Un <b>saque</b> a la red es <b>service_fault</b>.<br>\n&bull; <b>Cinta de red que se cuela y cae dentro</b>: en juego y válido &mdash; normalmente un <b>winner</b> si es inalcanzable, si no juzga lo que ocurre después. En el SAQUE varía según el deporte: tenis/tenis de mesa = <b>let</b> (se repite); roce de red en bádminton que pasa por encima y cae dentro = se sigue jugando (pero un volante de saque ATRAPADO en la red = service_fault); pickleball (2026) = se sigue jugando.<br>\n&bull; <b>¿Dudas entre forced y unforced?</b> Por defecto usa <b>unforced</b> &mdash; marca forced solo cuando puedas señalar la presión concreta.<br>\n<br>\nSalida: <i>&lt;video&gt;.rallies.csv</i> junto al vídeo. Guía completa: docs/ENDING_REASONS.md en el repositorio.<br>\nHaz clic en <b>Ocultar ayuda</b> para volver al panel de estado.",
  },
  ["da"] = {
    ["label.sport"] = "Sportsgren:",
    ["label.start"] = "Start (s):",
    ["label.end"] = "Slut (s):",
    ["label.next"] = "Næste dueloptræk #:",
    ["label.shots"] = "Antal slag:",
    ["label.reason"] = "Afslutningsårsag:",
    ["label.recent"] = "Seneste dueller (vælg én, derefter Rediger/Slet):",
    ["label.language"] = "Sprog:",
    ["btn.help"] = "Hjælp",
    ["btn.hideHelp"] = "Skjul hjælp",
    ["btn.back5"] = "Tilbage 5s",
    ["btn.playPause"] = "Afspil / Pause",
    ["btn.fwd5"] = "Frem 5s",
    ["btn.markStart"] = "Markér START",
    ["btn.markEnd"] = "Markér SLUT",
    ["btn.reMarkStart"] = "Markér START igen (#{n})",
    ["btn.reMarkEnd"] = "Markér SLUT igen (#{n})",
    ["btn.saveRally"] = "Gem duel",
    ["btn.saveRallyN"] = "Gem duel (#{n})",
    ["btn.saveChangesN"] = "Gem ændringer (#{n})",
    ["btn.edit"] = "Rediger valgte",
    ["btn.delete"] = "Slet valgte",
    ["btn.undo"] = "Fortryd seneste",
    ["btn.undoCancelEdit"] = "Fortryd seneste (annullér redigering)",
    ["btn.undoClearMark"] = "Fortryd seneste (ryd markering)",
    ["btn.undoN"] = "Fortryd seneste (#{n})",
    ["btn.refresh"] = "Opdater",
    ["reason.unknown"] = "ukendt",
    ["reason.winner"] = "vinderbold",
    ["reason.forced_error"] = "fremtvunget fejl",
    ["reason.unforced_error"] = "uprovokeret fejl",
    ["reason.service_fault"] = "servefejl",
    ["reason.let"] = "omserv",
    ["reason.other"] = "andet",
    ["sport.badminton"] = "badminton",
    ["sport.tennis"] = "tennis",
    ["sport.table_tennis"] = "bordtennis",
    ["sport.pickleball"] = "pickleball",
    ["sport.padel"] = "padel",
    ["status.modeEdit"] = "Tilstand: REDIGERER duel #{n}  (Gem ændringer for at bekræfte, Fortryd seneste for at annullere).",
    ["status.modeNew"] = "Tilstand: ny duel  (Markér START, Markér SLUT, vælg årsag, Gem duel).",
    ["status.lastRow"] = "Sidste række (det Fortryd fjerner): #{n}  {start} -> {end}  [{reason}]",
    ["status.footer"] = "Nu: {clock}  |  Dueller i CSV: {count}",
    ["status.csvPath"] = "CSV: {path}",
    ["seek.noMedia"] = "Ingen medier afspilles -- kan ikke søge.",
    ["seek.noTime"] = "Ingen afspilningstid tilgængelig at søge fra.",
    ["seek.done"] = "Søg {delta}s  ->  {clock}.",
    ["markStart.noMedia"] = "Ingen medier afspilles -- kan ikke markere START.",
    ["markStart.armed"] = "Du har en IKKE-GEMT duel (START -> SLUT). Klik 'Gem duel' for at beholde den, eller 'Fortryd seneste' for at rydde den, før du markerer en ny START. (Du kan også redigere Start-feltet manuelt.)",
    ["markStart.set"] = "START sat @ {clock}. Afspil til duellens slutning, og markér derefter SLUT.",
    ["markEnd.noMedia"] = "Ingen medier afspilles -- kan ikke markere SLUT.",
    ["markEnd.set"] = "SLUT sat @ {clock}. Vælg afslutningsårsagen, og klik derefter på Gem duel.",
    ["save.needStart"] = "Sæt en START-tid først (klik på Markér START).",
    ["save.needEnd"] = "Sæt en SLUT-tid først (klik på Markér SLUT).",
    ["save.zeroLen"] = "SLUT skal være senere end START (duellen skal være > 0s).",
    ["save.writeFailed"] = "SKRIVNING MISLYKKEDES: {err}",
    ["save.updated"] = "Opdaterede duel #{n}: {start} -> {end}  [{reason}, {sport}{shots}].",
    ["save.duplicate"] = "Duel #{n} findes allerede -- sæt \"Næste dueloptræk #\" til et ledigt nummer.",
    ["save.saved"] = "Gemte duel #{n}: {start} -> {end}  [{reason}, {sport}{shots}].",
    ["edit.armedGuard"] = "Afslut den aktuelle duel ('Gem duel') eller ryd den ('Fortryd seneste'), før du redigerer en anden -- din ikke-gemte START -> SLUT ville gå tabt.",
    ["edit.needSelect"] = "Vælg en duel i listen Seneste først, og klik derefter på Rediger valgte.",
    ["edit.notFound"] = "Duel #{n} blev ikke fundet (prøv Opdater).",
    ["edit.editing"] = "Redigerer duel #{n}. Justér Start/Slut/årsag, og klik derefter på Gem ændringer. (Fortryd seneste annullerer.)",
    ["del.needSelect"] = "Vælg en duel i listen Seneste først, og klik derefter på Slet valgte.",
    ["del.deleted"] = "Slettede duel #{n}. {count} tilbage.",
    ["undo.cancelled"] = "Redigering annulleret.",
    ["undo.cleared"] = "Ryddede den igangværende START/SLUT (intet blev skrevet).",
    ["undo.nothing"] = "Intet at fortryde.",
    ["undo.removed"] = "Fjernede seneste duel #{n}. {count} tilbage.",
    ["play.paused"] = "Sat på pause. Annotér (eller finjustér Start/Slut), og klik derefter på Afspil / Pause for at fortsætte.",
    ["play.resumed"] = "Afspilning genoptaget.",
    ["play.started"] = "Afspilning startet.",
    ["play.noMedia"] = "Ingen medier indlæst til afspilning.",
    ["sync.editFirst"] = "Afslut (Gem ændringer) eller annullér (Fortryd seneste) den aktuelle redigering, før du opdaterer.",
    ["sync.noMedia"] = "Ingen medier afspilles -- bruger stadig denne CSV. Åbn videoen, og klik derefter på Opdater.",
    ["sync.refreshed"] = "Opdateret. {count} dueller indlæst for denne video.",
    ["sync.switched"] = "Skiftede til den aktuelle video. Indlæste {count} eksisterende dueller; næste er #{n}.",
    ["activate.fallback"] = "Ingen video registreret endnu. Åbn/afspil videoen, og klik derefter på Markér START -- værktøjet skifter automatisk til den videos egen .rallies.csv (og indlæser eventuelle dueller, der allerede er gemt for den). Tip: åbn videoen FØRST, og aktivér derefter denne udvidelse.",
    ["activate.resumed"] = "Genoptog denne video: {count} eksisterende dueller indlæst (næste er #{n}). Klik på Hjælp for vejledningen.",
    ["activate.ready"] = "Klar. Vælg sportsgrenen, og markér derefter dueller. Klik på Hjælp for brug + vejledningen til afslutningsårsager.",
    ["help.html"] = "<b>Rally Annotator &mdash; sådan bruges det</b><br>\n<b>Afspilning:</b> rækken <b>Tilbage 5s / Afspil / Pause / Frem 5s</b> styrer VLC-afspilleren herfra &mdash; <b>Afspil / Pause</b> er én knap (sæt på pause, annotér, og fortsæt uden at skifte til VLC's hovedvindue).<br>\n1. Vælg <b>Sportsgren</b> (øverst). Den forbliver indstillet på tværs af rallies.<br>\n2. Når et rally begynder, klik <b>Markér START</b> (sæt på pause/spol først for billednøjagtighed &mdash; den fanger den aktuelle afspilningstid ind i Start-feltet).<br>\n3. Når rallyet slutter, klik <b>Markér SLUT</b>. Du kan finjustere Start/Slut-sekunderne ved at redigere disse felter direkte.<br>\n4. Vælg <b>Slutårsag</b> (boksen mellem <b>Markér SLUT</b> og <b>Gem rally</b>; eller lad den stå som <b>unknown</b>), skriv eventuelt et <b>Antal slag</b> (rallyets slag-/strøgtal &mdash; lad stå tomt for at springe over), og klik derefter <b>Gem rally</b> &mdash; én CSV-række skrives ved siden af videoen.<br>\n5. Årsagen NULSTILLES til <b>unknown</b> efter hver gemning (genbruges aldrig stiltiende), og du kan vælge samme årsag på flere rallies i træk.<br>\n6. <b>Seneste rallies</b>: vælg en række, og derefter <b>Redigér valgt</b> (indlæser den tilbage i felterne) eller <b>Slet valgt</b>. <b>Fortryd seneste</b> fjerner den nyeste række (knappen viser hvilken, f.eks. <i>Fortryd seneste (#7)</i>), eller rydder en igangværende markering, eller annullerer en redigering.<br>\n7. <b>Fortsæt senere:</b> labels gemmes i CSV-filen ved siden af videoen, mens du arbejder. Genåbn den SAMME video og aktivér udvidelsen &mdash; den genindlæser dine eksisterende rallies og fortsætter nummereringen. Indstil feltet <b>Næste rally #</b> for at genoptage nummereringen fra en hvilken som helst værdi (f.eks. genstart ved 1, eller fortsæt fra 50); det rykker automatisk frem efter hver gemning. Hvis du skifter video med denne dialog åben, klik <b>Opdatér</b> for at indlæse den aktuelle videos rallies. (Videoens afspilningsposition gendannes ikke &mdash; spol til der, hvor du stoppede.)<br>\n<br>\n<b>Slutårsager &mdash; hvad de betyder (vælg den, der siger HVORFOR rallyet sluttede).</b><br>\nAlle årsager undtagen <i>winner</i> tilskrives den side, der TABTE rallyet.<br>\n&bull; <b>winner</b> &mdash; det sidste slag landede INDE og blev ikke returneret (modstanderen kunne ikke nå det, eller pillede kun ved det). En ren urørt serv (es) tæller her.<br>\n&bull; <b>forced_error</b> &mdash; taberen MISSEDE (ude, eller i nettet) mens UNDER PRES: strakt, forhastet, klemt, eller i kamp med modstanderens fart/skru/dybde. De blev tvunget til at misse.<br>\n&bull; <b>unforced_error</b> &mdash; taberen MISSEDE et rutineslag, de havde både tid OG position til at ramme, med lidt eller intet pres. De forærede det væk.<br>\n&bull; <b>service_fault</b> &mdash; pointet sluttede på SERVEN: serv i nettet, ude af servefeltet, ulovlig bevægelse/fodfejl, eller en dobbeltfejl (tennis/padel).<br>\n&bull; <b>let</b> &mdash; rallyet SPILLES OM efter reglerne (intet point): f.eks. en tennis-/bordtennisserv, der strejfer nettet og ellers er god, eller udefrakommende forstyrrelse.<br>\n&bull; <b>other</b> &mdash; alt andet (skjult optagelse, skade/udgåen, straf, hindring). Brug sparsomt.<br>\n&bull; <b>unknown</b> &mdash; standardvalget; dette rally er endnu ikke klassificeret (vælg en specifik årsag, når du kan).<br>\n<br>\n<b>Hurtige eksempler</b><br>\n&bull; Bold/fjerbold lander <b>UDE</b> (forbi baglinjen / uden for linjerne): det er slagspillerens miss &mdash; <b>forced</b> hvis de var under pres, <b>unforced</b> hvis det var en behagelig bold. (UDE er IKKE automatisk forced, og aldrig en winner for modstanderen.)<br>\n&bull; <b>I nettet</b> under et rally: det samme &mdash; forced hvis presset, unforced hvis rutine. En <b>serv</b> i nettet er <b>service_fault</b>.<br>\n&bull; <b>Netkant, der trimler over og lander inde</b>: levende og god &mdash; normalt en <b>winner</b> hvis den ikke kan nås, ellers vurdér hvad der sker derefter. På SERVEN varierer det efter sportsgren: tennis/bordtennis = <b>let</b> (omspil); badminton-nettouch, der passerer over og lander inde = spil videre (men en servefjerbold FANGET på nettet = service_fault); pickleball (2026) = spil videre.<br>\n&bull; <b>I tvivl om forced vs unforced?</b> Vælg som standard <b>unforced</b> &mdash; markér kun forced, når du kan udpege det specifikke pres.<br>\n<br>\nOutput: <i>&lt;video&gt;.rallies.csv</i> ved siden af videoen. Fuld vejledning: docs/ENDING_REASONS.md i repoet.<br>\nKlik <b>Skjul hjælp</b> for at vende tilbage til statuspanelet.",
  },
  ["id"] = {
    ["label.sport"] = "Olahraga:",
    ["label.start"] = "Mulai (d):",
    ["label.end"] = "Akhir (d):",
    ["label.next"] = "Reli berikutnya #:",
    ["label.shots"] = "Jumlah pukulan:",
    ["label.reason"] = "Alasan berakhir:",
    ["label.recent"] = "Reli terbaru (pilih satu, lalu Edit/Hapus):",
    ["label.language"] = "Bahasa:",
    ["btn.help"] = "Bantuan",
    ["btn.hideHelp"] = "Sembunyikan bantuan",
    ["btn.back5"] = "Mundur 5d",
    ["btn.playPause"] = "Putar / Jeda",
    ["btn.fwd5"] = "Maju 5d",
    ["btn.markStart"] = "Tandai MULAI",
    ["btn.markEnd"] = "Tandai AKHIR",
    ["btn.reMarkStart"] = "Tandai ulang MULAI (#{n})",
    ["btn.reMarkEnd"] = "Tandai ulang AKHIR (#{n})",
    ["btn.saveRally"] = "Simpan Reli",
    ["btn.saveRallyN"] = "Simpan Reli (#{n})",
    ["btn.saveChangesN"] = "Simpan perubahan (#{n})",
    ["btn.edit"] = "Edit yang dipilih",
    ["btn.delete"] = "Hapus yang dipilih",
    ["btn.undo"] = "Urungkan terakhir",
    ["btn.undoCancelEdit"] = "Urungkan terakhir (batalkan edit)",
    ["btn.undoClearMark"] = "Urungkan terakhir (hapus tanda)",
    ["btn.undoN"] = "Urungkan terakhir (#{n})",
    ["btn.refresh"] = "Segarkan",
    ["reason.unknown"] = "tidak diketahui",
    ["reason.winner"] = "poin langsung",
    ["reason.forced_error"] = "kesalahan terpaksa",
    ["reason.unforced_error"] = "kesalahan sendiri",
    ["reason.service_fault"] = "kesalahan servis",
    ["reason.let"] = "let",
    ["reason.other"] = "lainnya",
    ["sport.badminton"] = "bulu tangkis",
    ["sport.tennis"] = "tenis",
    ["sport.table_tennis"] = "tenis meja",
    ["sport.pickleball"] = "pickleball",
    ["sport.padel"] = "padel",
    ["status.modeEdit"] = "Mode: MENGEDIT reli #{n}  (Simpan perubahan untuk menyimpan, Urungkan terakhir untuk membatalkan).",
    ["status.modeNew"] = "Mode: reli baru  (Tandai MULAI, Tandai AKHIR, pilih alasan, Simpan Reli).",
    ["status.lastRow"] = "Baris terakhir (yang dihapus oleh Urungkan): #{n}  {start} -> {end}  [{reason}]",
    ["status.footer"] = "Sekarang: {clock}  |  Reli dalam CSV: {count}",
    ["status.csvPath"] = "CSV: {path}",
    ["seek.noMedia"] = "Tidak ada media yang diputar -- tidak bisa mencari posisi.",
    ["seek.noTime"] = "Tidak ada waktu pemutaran sebagai titik awal pencarian.",
    ["seek.done"] = "Cari {delta}d  ->  {clock}.",
    ["markStart.noMedia"] = "Tidak ada media yang diputar -- tidak bisa menandai MULAI.",
    ["markStart.armed"] = "Anda memiliki reli yang BELUM TERSIMPAN (MULAI -> AKHIR). Klik 'Simpan Reli' untuk menyimpannya, atau 'Urungkan terakhir' untuk menghapusnya, sebelum menandai MULAI baru. (Anda juga bisa mengubah kolom Mulai secara manual.)",
    ["markStart.set"] = "MULAI ditetapkan @ {clock}. Putar hingga akhir reli, lalu Tandai AKHIR.",
    ["markEnd.noMedia"] = "Tidak ada media yang diputar -- tidak bisa menandai AKHIR.",
    ["markEnd.set"] = "AKHIR ditetapkan @ {clock}. Pilih alasan berakhir, lalu klik Simpan Reli.",
    ["save.needStart"] = "Tetapkan waktu MULAI terlebih dahulu (klik Tandai MULAI).",
    ["save.needEnd"] = "Tetapkan waktu AKHIR terlebih dahulu (klik Tandai AKHIR).",
    ["save.zeroLen"] = "AKHIR harus lebih lambat dari MULAI (reli harus > 0d).",
    ["save.writeFailed"] = "GAGAL MENULIS: {err}",
    ["save.updated"] = "Reli #{n} diperbarui: {start} -> {end}  [{reason}, {sport}{shots}].",
    ["save.duplicate"] = "Reli #{n} sudah ada -- atur \"Reli berikutnya #\" ke nomor yang kosong.",
    ["save.saved"] = "Reli #{n} tersimpan: {start} -> {end}  [{reason}, {sport}{shots}].",
    ["edit.armedGuard"] = "Selesaikan reli saat ini ('Simpan Reli') atau hapus ('Urungkan terakhir') sebelum mengedit yang lain -- MULAI -> AKHIR Anda yang belum tersimpan akan hilang.",
    ["edit.needSelect"] = "Pilih sebuah reli di daftar Terbaru terlebih dahulu, lalu Edit yang dipilih.",
    ["edit.notFound"] = "Reli #{n} tidak ditemukan (coba Segarkan).",
    ["edit.editing"] = "Mengedit reli #{n}. Sesuaikan Mulai/Akhir/alasan, lalu Simpan perubahan. (Urungkan terakhir untuk membatalkan.)",
    ["del.needSelect"] = "Pilih sebuah reli di daftar Terbaru terlebih dahulu, lalu Hapus yang dipilih.",
    ["del.deleted"] = "Reli #{n} dihapus. {count} tersisa.",
    ["undo.cancelled"] = "Edit dibatalkan.",
    ["undo.cleared"] = "MULAI/AKHIR yang sedang berlangsung telah dihapus (tidak ada yang ditulis).",
    ["undo.nothing"] = "Tidak ada yang bisa diurungkan.",
    ["undo.removed"] = "Reli terakhir #{n} dihapus. {count} tersisa.",
    ["play.paused"] = "Dijeda. Beri anotasi (atau sesuaikan Mulai/Akhir), lalu Putar / Jeda untuk melanjutkan.",
    ["play.resumed"] = "Pemutaran dilanjutkan.",
    ["play.started"] = "Pemutaran dimulai.",
    ["play.noMedia"] = "Tidak ada media yang dimuat untuk diputar.",
    ["sync.editFirst"] = "Selesaikan (Simpan perubahan) atau batalkan (Urungkan terakhir) edit saat ini sebelum menyegarkan.",
    ["sync.noMedia"] = "Tidak ada media yang diputar -- tetap menggunakan CSV ini. Buka videonya, lalu klik Segarkan.",
    ["sync.refreshed"] = "Disegarkan. {count} reli dimuat untuk video ini.",
    ["sync.switched"] = "Beralih ke video saat ini. Memuat {count} reli yang ada; berikutnya adalah #{n}.",
    ["activate.fallback"] = "Belum ada video terdeteksi. Buka/putar video, lalu klik Tandai MULAI -- alat akan otomatis beralih ke berkas .rallies.csv milik video tersebut (dan memuat reli yang sudah tersimpan untuknya). Tip: buka video DULU, lalu aktifkan ekstensi ini.",
    ["activate.resumed"] = "Melanjutkan video ini: {count} reli yang ada dimuat (berikutnya adalah #{n}). Klik Bantuan untuk panduan.",
    ["activate.ready"] = "Siap. Pilih Olahraga, lalu tandai reli. Klik Bantuan untuk cara pakai + panduan alasan berakhir.",
    ["help.html"] = "<b>Rally Annotator &mdash; cara penggunaan</b><br>\n<b>Pemutaran:</b> baris <b>Mundur 5d / Putar / Jeda / Maju 5d</b> mengendalikan pemutar VLC dari sini &mdash; <b>Putar / Jeda</b> adalah satu sakelar (jeda, beri anotasi, lalu lanjutkan tanpa beralih ke jendela utama VLC).<br>\n1. Pilih <b>Olahraga</b> (di atas). Pengaturan ini tetap berlaku di seluruh reli.<br>\n2. Saat sebuah reli dimulai, klik <b>Tandai MULAI</b> (jeda/geser dulu untuk akurasi per-bingkai &mdash; ini mengambil cuplikan waktu pemutaran saat ini ke kolom Mulai).<br>\n3. Saat reli berakhir, klik <b>Tandai SELESAI</b>. Anda dapat menyetel halus detik Mulai/Selesai dengan menyunting kolom-kolom tersebut secara langsung.<br>\n4. Pilih <b>Alasan berakhir</b> (kotak di antara <b>Tandai SELESAI</b> dan <b>Simpan Reli</b>; atau biarkan sebagai <b>unknown</b>), opsional ketikkan <b>Jumlah pukulan</b> (jumlah pukulan/ayunan dalam reli &mdash; kosongkan untuk melewati), lalu klik <b>Simpan Reli</b> &mdash; satu baris CSV ditulis di samping video.<br>\n5. Alasan akan DIATUR ULANG menjadi <b>unknown</b> setelah setiap penyimpanan (tidak pernah dipakai ulang secara diam-diam), dan Anda dapat memilih alasan yang sama pada reli-reli berturut-turut.<br>\n6. <b>Reli terbaru</b>: pilih sebuah baris, lalu <b>Sunting yang dipilih</b> (memuatnya kembali ke kolom-kolom) atau <b>Hapus yang dipilih</b>. <b>Batalkan terakhir</b> menghapus baris yang paling baru (tombol menunjukkan yang mana, mis. <i>Batalkan terakhir (#7)</i>), atau menghapus tanda yang sedang berjalan, atau membatalkan suntingan.<br>\n7. <b>Melanjutkan nanti:</b> label disimpan ke CSV di samping video seiring kerja Anda. Buka kembali video yang SAMA dan aktifkan ekstensi &mdash; ia akan memuat ulang reli yang sudah ada dan melanjutkan penomoran. Atur kolom <b>Reli berikutnya #</b> untuk melanjutkan penomoran dari nilai mana pun (mis. mulai ulang dari 1, atau lanjutkan dari 50); ia akan otomatis maju setelah setiap penyimpanan. Jika Anda berganti video dengan dialog ini terbuka, klik <b>Segarkan</b> untuk memuat reli dari video saat ini. (Posisi pemutaran video tidak dipulihkan &mdash; geser ke tempat Anda berhenti.)<br>\n<br>\n<b>Alasan berakhir &mdash; apa artinya (pilih yang menyatakan MENGAPA reli berakhir).</b><br>\nSemua alasan kecuali <i>winner</i> dibebankan kepada pihak yang KALAH dalam reli.<br>\n&bull; <b>winner</b> &mdash; pukulan terakhir mendarat MASUK dan tidak dikembalikan (lawan tidak mampu menjangkaunya, atau hanya melambai padanya). Servis bersih yang tak tersentuh (ace) termasuk di sini.<br>\n&bull; <b>forced_error</b> &mdash; pihak yang kalah MELESET (keluar, atau ke net) saat DALAM TEKANAN: terentang, terburu-buru, terjepit, atau kesulitan menangani tempo/spin/kedalaman lawan. Mereka dipaksa untuk meleset.<br>\n&bull; <b>unforced_error</b> &mdash; pihak yang kalah MELESET pada pukulan rutin yang mereka punya waktu DAN posisi untuk melakukannya, dengan sedikit atau tanpa tekanan. Mereka memberikannya cuma-cuma.<br>\n&bull; <b>service_fault</b> &mdash; poin berakhir pada SERVIS: servis ke net, keluar dari kotak servis, gerakan ilegal/foot fault, atau servis ganda gagal (tenis/padel).<br>\n&bull; <b>let</b> &mdash; reli DIULANG sesuai aturan (tanpa poin): mis. servis tenis/tenis meja yang menyentuh net tetapi sebaliknya sah, atau gangguan dari luar.<br>\n&bull; <b>other</b> &mdash; apa pun selain itu (rekaman terhalang, cedera/mundur, penalti, halangan). Gunakan secukupnya.<br>\n&bull; <b>unknown</b> &mdash; nilai bawaan; reli ini belum diklasifikasikan (pilih alasan spesifik bila Anda bisa).<br>\n<br>\n<b>Kasus singkat</b><br>\n&bull; Bola/kok mendarat <b>KELUAR</b> (melewati garis belakang / di luar garis): itu adalah lesetnya pemukul &mdash; <b>forced</b> jika mereka dalam tekanan, <b>unforced</b> jika itu bola yang nyaman. (KELUAR TIDAK otomatis forced, dan tidak pernah menjadi winner bagi lawan.)<br>\n&bull; <b>Ke net</b> selama reli: sama saja &mdash; forced jika ditekan, unforced jika rutin. <b>Servis</b> ke net adalah <b>service_fault</b>.<br>\n&bull; <b>Sentuhan net yang menggelinding melewatinya dan mendarat masuk</b>: tetap hidup dan sah &mdash; biasanya <b>winner</b> jika tak terjangkau, jika tidak nilailah apa yang terjadi berikutnya. Pada SERVIS hal ini bervariasi menurut olahraga: tenis/tenis meja = <b>let</b> (ulang); sentuhan net pada bulu tangkis yang melewatinya dan mendarat masuk = lanjut bermain (tetapi kok servis yang TERSANGKUT di net = service_fault); pickleball (2026) = lanjut bermain.<br>\n&bull; <b>Ragu antara forced dan unforced?</b> Standarkan ke <b>unforced</b> &mdash; tandai forced hanya bila Anda dapat menunjuk tekanan yang spesifik.<br>\n<br>\nKeluaran: <i>&lt;video&gt;.rallies.csv</i> di samping video. Panduan lengkap: docs/ENDING_REASONS.md di repositori.<br>\nKlik <b>Sembunyikan bantuan</b> untuk kembali ke panel status.",
  },
}

local LOCALES = { "en", "kn", "hi", "te", "es", "da", "id" }
local LOCALE_LABELS = { en = "English", kn = "ಕನ್ನಡ", hi = "हिन्दी", te = "తెలుగు",
                        es = "Español", da = "Dansk", id = "Bahasa Indonesia" }
local LANG = "en"

-- t(key, vars): current locale -> en -> raw key, with {var} interpolation. (gsub/ipairs
-- live in function bodies, never at top level, so the descriptor() scan sandbox is fine.)
local function t(key, vars)
  local tbl = STRINGS[LANG] or STRINGS.en
  local s = (tbl and tbl[key]) or (STRINGS.en and STRINGS.en[key]) or key
  if vars then
    s = s:gsub("{(%w+)}", function(k)
      local v = vars[k]
      if v == nil then return "{" .. k .. "}" end
      return tostring(v)
    end)
  end
  return s
end

local function lang_index(code)
  for i, c in ipairs(LOCALES) do if c == code then return i end end
  return 1
end

-- Persist the chosen language in a tiny config file (extensions have no settings API).
local function lang_config_path()
  local home = os.getenv("USERPROFILE") or os.getenv("HOME") or "."
  local sep = home:find("\\") and "\\" or "/"
  if home:sub(-1) ~= sep then home = home .. sep end
  return home .. ".rally_annotator_lang"
end
local function load_lang()
  local f = io.open(lang_config_path(), "r")
  if not f then return end
  local code = f:read("*l"); f:close()
  if code then code = code:gsub("%s+", "") end
  if code and STRINGS[code] then LANG = code end
end
local function save_lang()
  local f = io.open(lang_config_path(), "w")
  if f then f:write(LANG .. "\n"); f:close() end
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local d                 -- the single dialog (one per extension)
local w_status          -- status label widget (HTML/rich-text); also hosts help
local w_reason          -- ending_reason dropdown widget
local w_sport           -- sport dropdown widget
local w_start           -- start-time text input (editable seconds)
local w_end             -- end-time text input (editable seconds)
local w_list            -- recent-rallies list widget
local w_save            -- "Save Rally" / "Save changes" button (relabeled by state)
local w_mark_start      -- "Mark START" button (relabeled "Re-mark START (#N)" while editing)
local w_mark_end        -- "Mark END" button (relabeled "Re-mark END (#N)" while editing)
local w_undo            -- "Undo last" button (relabeled to show which row it removes)
local w_next            -- "Next rally #" text input (lets you resume numbering anywhere)
local w_shots           -- "Number of shots" text input (optional shots_count per rally)
local w_help_btn        -- the Help button (relabeled "Hide help" when open)
local w_help            -- the help panel widget; nil when hidden (toggled via del_widget)
local w_lang            -- language-selector dropdown (en/kn/hi/te/es/da/id)

local rows = {}         -- in-memory rally rows: { n, s, e, reason, sport, [shots], [extra] }
local mode = "new"      -- "new" (marking a fresh rally) or "edit" (editing a row)
local edit_index = nil  -- index into rows when mode == "edit"
local out_path          -- resolved CSV path (set on activate; re-resolved by Refresh)
local out_path_is_fallback = false  -- true when out_path is the home-dir fallback (no video
                                    -- was resolvable when we last set it); see adopt_current_video_csv

--------------------------------------------------------------------------------
-- Helpers (declared before the global callbacks that capture them)
--------------------------------------------------------------------------------

-- Current playback time in SECONDS, or nil if nothing is playing.
local function now_seconds()
  local input = vlc.object.input()
  if not input then return nil end
  local t_us = vlc.var.get(input, "time")   -- MICROSECONDS in VLC 3.x
  if not t_us then return nil end
  return t_us / 1000000.0
end

-- mm:ss.mmm for display only.
local function fmt_clock(s)
  if not s then return "--:--" end
  if s < 0 then s = 0 end
  local m   = math.floor(s / 60)
  local sec = s - m * 60
  return string.format("%d:%06.3f", m, sec)
end

-- Minimal HTML-escape so paths/messages render literally in the rich-text label.
local function esc(text)
  text = tostring(text or "")
  text = text:gsub("&", "&amp;")
  text = text:gsub("<", "&lt;")
  text = text:gsub(">", "&gt;")
  return text
end

-- Best-effort path to the currently playing media file (decoded from URI).
local function current_media_path()
  local input = vlc.object.input()
  if not input then return nil end
  local item = vlc.input.item()           -- VLC 3.x: vlc.input.item()
  if not item then return nil end
  local uri = item:uri()                   -- item:uri()
  if not uri or uri == "" then return nil end
  local p = uri
  -- Strip the scheme. Windows file URIs look like file:///C:/dir/clip.mp4;
  -- POSIX ones like file:///home/user/clip.mp4 -- keep the POSIX leading "/".
  if p:match("^file:///%a:") then
    p = p:gsub("^file:///", "")            -- file:///C:/... -> C:/...
  else
    p = p:gsub("^file://", "")             -- file:///home/... -> /home/...
  end
  -- percent-decode (e.g. %20 -> space) BEFORE separator normalization
  p = p:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  if p:match("^%a:") then                  -- Windows drive path -> backslashes
    p = p:gsub("/", "\\")
  end
  return p
end

-- Resolve a sensible default output path: next to the video if we can, else
-- the user's home (USERPROFILE on Windows, HOME elsewhere).
local function resolve_out_path()
  local media = current_media_path()
  if media then
    local dir, stem = media:match("^(.*[\\/])([^\\/]-)%.?[^\\/%.]*$")
    if dir and stem and stem ~= "" then
      return dir .. stem .. ".rallies.csv"
    end
    local d2 = media:match("^(.*[\\/])")
    if d2 then return d2 .. "rally_labels.csv" end
  end
  local home = os.getenv("USERPROFILE") or os.getenv("HOME") or "."
  local sep = home:find("\\") and "\\" or "/"
  if home:sub(-1) ~= sep then home = home .. sep end
  return home .. "rally_labels.csv"
end

-- Load all rally rows from the CSV into `rows` (header + blank lines skipped).
-- Forgiving parser: any leading-integer line is a rally row. Column 6 is the
-- optional shots_count (blank/missing in older CSVs); any columns beyond it are
-- preserved verbatim so we never drop richer metadata on rewrite.
local function load_rows()
  rows = {}
  local f = io.open(out_path, "r")
  if not f then return end
  for line in f:lines() do
    line = line:gsub("\r$", "")
    if line:match("%S") then
      local parts = {}
      for field in (line .. ","):gmatch("([^,]*),") do parts[#parts + 1] = field end
      local n = tonumber(parts[1])
      if n and n == math.floor(n) then
        local shots = parts[6]
        if shots == "" then shots = nil end   -- blank => not recorded
        local row = {
          n      = math.floor(n),
          s      = tonumber(parts[2]) or 0,
          e      = tonumber(parts[3]) or 0,
          reason = (parts[4] ~= nil and parts[4] ~= "") and parts[4] or "other",
          sport  = parts[5] or "",
          shots  = shots,
        }
        if #parts > 6 then
          local ex = {}
          for i = 7, #parts do ex[#ex + 1] = parts[i] end
          row.extra = table.concat(ex, ",")
        end
        rows[#rows + 1] = row
      end
    end
  end
  f:close()
end

-- Rewrite the whole CSV from `rows` (header once). We write a temp file and swap
-- it into place so the live CSV is never lost if a step fails: rename is atomic on
-- POSIX (and succeeds for a brand-new file on Windows); when Windows can't rename
-- over an existing file we stash the original as .bak and roll back on error.
local function save_all()
  local tmp = out_path .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then return false, ("cannot open CSV for write: " .. tostring(err)) end
  f:write(HEADER)
  for _, r in ipairs(rows) do
    local shots = (r.shots ~= nil) and tostring(r.shots) or ""
    local line = string.format("%d,%.3f,%.3f,%s,%s,%s", r.n, r.s, r.e, r.reason, r.sport, shots)
    if r.extra and r.extra ~= "" then line = line .. "," .. r.extra end
    f:write(line .. "\n")
  end
  f:close()
  -- Atomic on POSIX; also succeeds on Windows when out_path doesn't exist yet.
  if os.rename(tmp, out_path) then return true end
  -- Windows overwrite path: keep a backup so the original is never lost.
  local bak = out_path .. ".bak"
  os.remove(bak)
  local stashed = os.rename(out_path, bak)        -- move original aside (nil if none)
  local ok, rerr = os.rename(tmp, out_path)
  if not ok then
    if stashed then os.rename(bak, out_path) end  -- roll back
    return false, ("cannot replace CSV: " .. tostring(rerr))
  end
  os.remove(bak)
  return true
end

-- Next monotonic rally_number (max existing + 1); keeps numbering across reopen.
local function next_rally_number()
  local maxn = 0
  for _, r in ipairs(rows) do if r.n > maxn then maxn = r.n end end
  return maxn + 1
end

-- Read a text-input widget as a number, or nil if blank/non-numeric.
local function get_field_num(w)
  if not w then return nil end
  local t = w:get_text()
  if not t then return nil end
  t = t:gsub("%s+", "")
  if t == "" then return nil end
  return tonumber(t)
end

-- The "Number of shots" field as a non-negative integer, or nil if blank or not a
-- valid count. Optional metadata: a blank/garbage value just records no shots_count.
local function get_shots()
  local v = get_field_num(w_shots)
  if not v or v < 0 then return nil end
  return math.floor(v)
end

-- True when a fresh rally is fully marked (both START and END) but NOT yet saved --
-- i.e. there is unsaved work in the fields. Guards against silently discarding it when
-- the user starts a new rally (Mark START) or jumps to editing another (Edit selected).
local function is_armed()
  return mode == "new" and get_field_num(w_start) ~= nil and get_field_num(w_end) ~= nil
end

-- The number the NEXT new rally will get. Defaults to next_rally_number(), but the
-- user can type any value into the "Next rally #" field to resume/insert anywhere.
local function planned_next_number()
  local v = get_field_num(w_next)
  if v and v >= 1 then return math.floor(v) end
  return next_rally_number()
end

-- Reset the "Next rally #" field to the natural next number for the current CSV.
local function refresh_next_field()
  if w_next then w_next:set_text(tostring(next_rally_number())) end
end

local function index_of_rally(n)
  for i, r in ipairs(rows) do if r.n == n then return i end end
  return nil
end

-- Smallest integer >= start that is not already a rally_number (auto-advance skips
-- over occupied numbers so consecutive saves never walk into an existing one).
local function next_free_from(start)
  local n = start
  while index_of_rally(n) do n = n + 1 end
  return n
end

-- First selected rally_number in the recent list, or nil. get_selection() returns
-- a { [id]=text } table in VLC 3.0.x (id is the rally_number we stored).
local function selected_rally_number()
  if not w_list then return nil end
  local sel = w_list:get_selection()
  if type(sel) ~= "table" then return nil end
  for id, _ in pairs(sel) do
    return tonumber(id) or id
  end
  return nil
end

-- Dropdowns have no set_value in 3.0.x. clear()+re-add did NOT repaint reliably in
-- VLC (the selection got "stuck" on the previous reason), so we RECREATE the dropdown
-- at the SAME grid cell via del_widget+add_dropdown -- a real widget swap VLC renders
-- every time, with no net layout change. The first value added is auto-selected, so we
-- add the value we want shown first.
local function rebuild_reason_default()
  if not d then return end
  if w_reason then d:del_widget(w_reason) end
  w_reason = d:add_dropdown(3, 6, 1, 1)
  w_reason:add_value(t("reason." .. REASON_DEFAULT), 0)  -- "unknown" default (id 0); label localized
  for i, v in ipairs(REASONS) do w_reason:add_value(t("reason." .. v), i) end
end

local function rebuild_reason_selected(sel)
  if not d then return end
  if not sel or sel == "" then sel = REASON_DEFAULT end
  if w_reason then d:del_widget(w_reason) end
  w_reason = d:add_dropdown(3, 6, 1, 1)
  w_reason:add_value(t("reason." .. sel), REASON_ID[sel] or 0)   -- selected first (label localized)
  if sel ~= REASON_DEFAULT then w_reason:add_value(t("reason." .. REASON_DEFAULT), 0) end
  for i, v in ipairs(REASONS) do
    if v ~= sel then w_reason:add_value(t("reason." .. v), i) end
  end
end

local function rebuild_sport_selected(sel)
  if not w_sport then return end
  if not sel or sel == "" then sel = SPORTS[1] end
  w_sport:clear()
  local id = SPORT_ID[sel] or 99
  w_sport:add_value(t("sport." .. sel), id)         -- first => shown selected (label localized)
  for i, v in ipairs(SPORTS) do
    if v ~= sel then w_sport:add_value(t("sport." .. v), i) end
  end
end

-- Repaint the recent-rallies list with EVERY rally (oldest first). The box is a
-- fixed-height, scrollable list, so we show the full history instead of a window --
-- a "last 12" cap used to hide the oldest rallies (e.g. #1 once you had 13+), which
-- also made them impossible to select for Edit/Delete.
local function refresh_list()
  if not w_list then return end
  w_list:clear()
  for _, r in ipairs(rows) do
    local label = string.format("#%d   %s -> %s   [%s, %s]", r.n, fmt_clock(r.s), fmt_clock(r.e),
      t("reason." .. r.reason), t("sport." .. r.sport))
    if r.shots ~= nil then label = label .. string.format("   %s shots", tostring(r.shots)) end
    w_list:add_value(label, r.n)
  end
  if d then d:update() end
end

-- Action-button labels reflect state. Save shows the rally number it will write
-- (or "Save changes (#N)" while editing). Undo last shows exactly which row it
-- will remove ("Undo last (#N)"), or that it will cancel an edit / clear a mark.
local function refresh_buttons()
  if w_save then
    if mode == "edit" and edit_index and rows[edit_index] then
      w_save:set_text(t("btn.saveChangesN", { n = rows[edit_index].n }))
    else
      local s = get_field_num(w_start)
      local e = get_field_num(w_end)
      if s and e then
        w_save:set_text(t("btn.saveRallyN", { n = planned_next_number() }))
      else
        w_save:set_text(t("btn.saveRally"))
      end
    end
  end
  -- While editing, the Mark buttons re-mark the EDITED rally's times (not a new one),
  -- so relabel them to make that unmissable -- a forgotten edit-mode is how you'd
  -- accidentally overwrite an existing rally thinking you were creating a new one.
  if w_mark_start and w_mark_end then
    if mode == "edit" and edit_index and rows[edit_index] then
      w_mark_start:set_text(t("btn.reMarkStart", { n = rows[edit_index].n }))
      w_mark_end:set_text(t("btn.reMarkEnd", { n = rows[edit_index].n }))
    else
      w_mark_start:set_text(t("btn.markStart"))
      w_mark_end:set_text(t("btn.markEnd"))
    end
  end
  if w_undo then
    if mode == "edit" then
      w_undo:set_text(t("btn.undoCancelEdit"))
    else
      local s = get_field_num(w_start)
      local e = get_field_num(w_end)
      if s or e then
        w_undo:set_text(t("btn.undoClearMark"))
      elseif #rows > 0 then
        w_undo:set_text(t("btn.undoN", { n = rows[#rows].n }))
      else
        w_undo:set_text(t("btn.undo"))
      end
    end
  end
  if d then d:update() end
end

local function set_status(msg)
  if not w_status then return end
  local mode_line
  if mode == "edit" and edit_index and rows[edit_index] then
    mode_line = t("status.modeEdit", { n = rows[edit_index].n })
  else
    mode_line = t("status.modeNew")
  end
  local last_line = ""
  if #rows > 0 then
    local lr = rows[#rows]
    last_line = esc(t("status.lastRow", { n = lr.n, start = fmt_clock(lr.s),
      ["end"] = fmt_clock(lr.e), reason = t("reason." .. lr.reason) })) .. "<br>"
  end
  local footer = t("status.footer", { clock = fmt_clock(now_seconds()), count = #rows })
  local csvline = t("status.csvPath", { path = out_path })
  w_status:set_text(esc(msg) .. "<br>" .. esc(mode_line) .. "<br>" .. last_line
    .. esc(footer) .. "<br>" .. esc(csvline))
  if d then d:update() end
end

-- Clear the form back to a fresh "new rally" state (reason reset = non-sticky).
local function reset_form()
  mode = "new"
  edit_index = nil
  if w_start then w_start:set_text("") end
  if w_end then w_end:set_text("") end
  if w_shots then w_shots:set_text("") end
  rebuild_reason_default()
  refresh_buttons()
  if d then d:update() end
end

-- Re-resolve the CSV path against whatever video is playing NOW and load its
-- labels. Lets the user open a video later (or switch videos) and pick up exactly
-- where they left off without toggling the extension off/on. Same video -> just
-- re-read the CSV; a different video -> repoint and load that video's rallies.
local function sync_to_current_video()
  if mode == "edit" then
    -- Reloading rows would invalidate edit_index; make the user resolve the edit first.
    refresh_list(); refresh_buttons()
    set_status(t("sync.editFirst"))
    return
  end
  local media = current_media_path()
  if not media then
    refresh_list(); refresh_buttons()
    set_status(t("sync.noMedia"))
    return
  end
  out_path_is_fallback = false   -- a video is playing now -> we have a real path
  local new_path = resolve_out_path()
  if new_path == out_path then
    load_rows()                  -- re-read in case the file changed on disk
    refresh_next_field()
    refresh_list(); refresh_buttons()
    set_status(t("sync.refreshed", { count = #rows }))
    return
  end
  out_path = new_path            -- switched videos -> repoint + resume that file
  load_rows()
  reset_form()
  refresh_next_field()
  refresh_list()
  refresh_buttons()
  set_status(t("sync.switched", { count = #rows, n = next_rally_number() }))
end

-- Lazily adopt the playing video's CSV. We may have started on the home-dir FALLBACK
-- (extension enabled before the video was loaded, so no path was resolvable then). The
-- moment a timestamp exists the video is provably playing, so switch to <video>.rallies.csv
-- and load that video's existing rallies BEFORE anything is written to the fallback -- this
-- is what makes "enable, then open the video" and pause/restart resume correctly instead of
-- silently writing to ~/rally_labels.csv. No-op once we're already on a real video CSV.
local function adopt_current_video_csv()
  if not out_path_is_fallback then return end
  local media = current_media_path()
  if not media then return end           -- still no video -> stay on the fallback for now
  out_path_is_fallback = false           -- a real path is resolvable now
  local p = resolve_out_path()
  if p == out_path then return end       -- already pointing there (defensive)
  out_path = p
  load_rows()                            -- pick up rallies already saved for this video
  refresh_next_field()
  refresh_list()
end

-- Seek the player by delta_s seconds (relative), clamped at 0 (time is microseconds in 3.x).
local function seek_by(delta_s)
  local input = vlc.object.input()
  if not input then set_status(t("seek.noMedia")); return end
  local cur = vlc.var.get(input, "time")   -- microseconds (named 'cur', not 't', to not shadow t())
  if not cur then set_status(t("seek.noTime")); return end
  local nt = cur + delta_s * 1000000
  if nt < 0 then nt = 0 end
  vlc.var.set(input, "time", nt)
  set_status(t("seek.done", { delta = string.format("%+d", delta_s), clock = fmt_clock(nt / 1000000.0) }))
end

--------------------------------------------------------------------------------
-- Button callbacks (VLC calls these on its main loop; kept global to be safe)
--------------------------------------------------------------------------------
function mark_start()
  local now = now_seconds()
  if not now then set_status(t("markStart.noMedia")); return end
  if is_armed() then
    set_status(t("markStart.armed"))
    return
  end
  adopt_current_video_csv()   -- video is playing now: make sure we're on its CSV, not the fallback
  w_start:set_text(string.format("%.3f", now))
  refresh_buttons()
  set_status(t("markStart.set", { clock = fmt_clock(now) }))
end

function mark_end()
  local now = now_seconds()
  if not now then set_status(t("markEnd.noMedia")); return end
  w_end:set_text(string.format("%.3f", now))
  refresh_buttons()
  set_status(t("markEnd.set", { clock = fmt_clock(now) }))
end

function save_rally()
  adopt_current_video_csv()   -- in case times were typed by hand without Mark START
  local s = get_field_num(w_start)
  local e = get_field_num(w_end)
  if not s then set_status(t("save.needStart")); return end
  if not e then set_status(t("save.needEnd")); return end
  if e < s then s, e = e, s end   -- tolerate reversed marks
  if e <= s then
    set_status(t("save.zeroLen"))
    return
  end
  -- Map the selected dropdown IDs back to CANONICAL english values (the displayed labels
  -- are localized, but the CSV must stay canonical). id 0 = unknown; 1..N index REASONS/SPORTS.
  local rid = w_reason:get_value()
  local reason = (rid == nil or rid == 0) and REASON_DEFAULT or (REASONS[rid] or REASON_DEFAULT)
  local sid = w_sport:get_value()
  local sport = (sid ~= nil and SPORTS[sid]) or SPORTS[1]
  local shots = get_shots()                -- optional; nil when blank
  local shots_note = (shots ~= nil) and string.format(", %d shots", shots) or ""

  local msg
  if mode == "edit" and edit_index and rows[edit_index] then
    local r = rows[edit_index]
    r.s, r.e, r.reason, r.sport, r.shots = s, e, reason, sport, shots
    local ok, err = save_all()
    if not ok then set_status(t("save.writeFailed", { err = tostring(err) })); return end
    msg = t("save.updated", { n = r.n, start = fmt_clock(s), ["end"] = fmt_clock(e),
      reason = t("reason." .. reason), sport = t("sport." .. sport), shots = shots_note })
  else
    local n = planned_next_number()
    if index_of_rally(n) then
      set_status(t("save.duplicate", { n = n }))
      return
    end
    rows[#rows + 1] = { n = n, s = s, e = e, reason = reason, sport = sport, shots = shots }
    local ok, err = save_all()
    if not ok then rows[#rows] = nil; set_status(t("save.writeFailed", { err = tostring(err) })); return end
    if w_next then w_next:set_text(tostring(next_free_from(n + 1))) end   -- next free number
    msg = t("save.saved", { n = n, start = fmt_clock(s), ["end"] = fmt_clock(e),
      reason = t("reason." .. reason), sport = t("sport." .. sport), shots = shots_note })
  end

  reset_form()       -- clears fields + resets the (required) reason to placeholder
  refresh_list()
  set_status(msg)
end

function edit_selected()
  if is_armed() then
    set_status(t("edit.armedGuard"))
    return
  end
  local n = selected_rally_number()
  if not n then set_status(t("edit.needSelect")); return end
  local idx = index_of_rally(n)
  if not idx then set_status(t("edit.notFound", { n = n })); return end
  local r = rows[idx]
  mode = "edit"; edit_index = idx
  w_start:set_text(string.format("%.3f", r.s))
  w_end:set_text(string.format("%.3f", r.e))
  if w_shots then w_shots:set_text(r.shots ~= nil and tostring(r.shots) or "") end
  rebuild_reason_selected(r.reason)
  rebuild_sport_selected(r.sport)
  refresh_buttons()
  set_status(t("edit.editing", { n = r.n }))
end

function delete_selected()
  local n = selected_rally_number()
  if not n then set_status(t("del.needSelect")); return end
  local idx = index_of_rally(n)
  if not idx then set_status(t("edit.notFound", { n = n })); return end
  table.remove(rows, idx)
  local ok, err = save_all()
  if not ok then set_status(t("save.writeFailed", { err = tostring(err) })); return end
  reset_form()
  refresh_next_field()
  refresh_list()
  set_status(t("del.deleted", { n = n, count = #rows }))
end

function undo_last()
  if mode == "edit" then
    reset_form(); refresh_list(); set_status(t("undo.cancelled"))
    return
  end
  local s = get_field_num(w_start)
  local e = get_field_num(w_end)
  if s or e then
    reset_form()
    set_status(t("undo.cleared"))
    return
  end
  if #rows == 0 then set_status(t("undo.nothing")); return end
  local last = rows[#rows]
  rows[#rows] = nil
  local ok, err = save_all()
  if not ok then rows[#rows + 1] = last; set_status(t("save.writeFailed", { err = tostring(err) })); return end
  refresh_list()
  refresh_next_field()
  refresh_buttons()
  set_status(t("undo.removed", { n = last.n, count = #rows }))
end

function refresh_now()
  sync_to_current_video()
end

-- Playback control (verified available to VLC 3.x extensions). pause() is a TOGGLE
-- (playlist_TogglePause), so we branch on status() to keep one Play / Pause button
-- deterministic: pause() flips playing<->paused, and from stopped we play() fresh.
function play_pause()
  local st = vlc.playlist.status()
  if st == "playing" then
    vlc.playlist.pause()        -- toggles playing -> paused
    set_status(t("play.paused"))
  elseif st == "paused" then
    vlc.playlist.pause()        -- toggles paused -> playing
    set_status(t("play.resumed"))
  elseif st == "stopped" then
    vlc.playlist.play()
    set_status(t("play.started"))
  else
    set_status(t("play.noMedia"))
  end
end

function seek_back() seek_by(-5) end
function seek_fwd()  seek_by(5) end

function show_help()
  -- Toggle a DEDICATED help panel by adding/removing a widget. In-place set_text on
  -- the shared status widget did not repaint reliably in VLC (the panel got "stuck");
  -- add_html + del_widget forces a real layout change that VLC renders every time.
  if w_help then
    if d then d:del_widget(w_help) end
    w_help = nil
    if w_help_btn then w_help_btn:set_text(t("btn.help")) end
  else
    if d then w_help = d:add_html(t("help.html"), 1, 16, 4, 8) end
    if w_help_btn then w_help_btn:set_text(t("btn.hideHelp")) end
  end
  if d then d:update() end
end

--------------------------------------------------------------------------------
-- Dialog construction
--------------------------------------------------------------------------------
local function create_dialog()
  d = vlc.dialog("Rally Annotator v" .. VERSION)

  d:add_label(t("label.sport"), 1, 1, 1, 1)
  w_sport = d:add_dropdown(2, 1, 2, 1)
  for i, v in ipairs(SPORTS) do w_sport:add_value(t("sport." .. v), i) end   -- badminton first => default
  w_help_btn = d:add_button(t("btn.help"), show_help, 4, 1, 1, 1)

  -- Playback controls -- one row of 3: Back 5s | Play / Pause (toggle) | Fwd 5s.
  d:add_button(t("btn.back5"),     seek_back,  1, 2, 1, 1)
  d:add_button(t("btn.playPause"), play_pause, 2, 2, 2, 1)   -- spans cols 2-3, centered
  d:add_button(t("btn.fwd5"),      seek_fwd,   4, 2, 1, 1)

  d:add_label(t("label.start"), 1, 3, 1, 1)
  w_start = d:add_text_input("", 2, 3, 1, 1)
  d:add_label(t("label.end"), 3, 3, 1, 1)
  w_end = d:add_text_input("", 4, 3, 1, 1)

  d:add_label(t("label.next"), 1, 4, 1, 1)
  w_next = d:add_text_input("", 2, 4, 1, 1)
  d:add_label(t("label.shots"), 3, 4, 1, 1)   -- optional; blank => shots_count left empty
  w_shots = d:add_text_input("", 4, 4, 1, 1)

  d:add_label(t("label.reason"), 3, 5, 1, 1)   -- labels the reason dropdown directly below it

  -- Per-rally commit row, left-to-right: Mark START -> Mark END -> reason -> Save.
  w_mark_start = d:add_button(t("btn.markStart"), mark_start, 1, 6, 1, 1)
  w_mark_end   = d:add_button(t("btn.markEnd"),   mark_end,   2, 6, 1, 1)
  rebuild_reason_default()                     -- creates w_reason at (3,6,1,1), under its label
  w_save = d:add_button(t("btn.saveRally"), save_rally, 4, 6, 1, 1)

  w_status = d:add_html("", 1, 7, 4, 2)   -- rich-text status panel (multi-line via <br>)

  d:add_label(t("label.recent"), 1, 9, 4, 1)
  w_list = d:add_list(1, 10, 4, 4)

  d:add_button(t("btn.edit"),   edit_selected,   1, 14, 1, 1)
  d:add_button(t("btn.delete"), delete_selected, 2, 14, 1, 1)
  w_undo = d:add_button(t("btn.undo"), undo_last, 3, 14, 1, 1)
  d:add_button(t("btn.refresh"), refresh_now,     4, 14, 1, 1)

  -- Language selector (row 15). VLC dropdowns have no change-callback, so a small "✓"
  -- button applies the choice and rebuilds the dialog. "✓" is language-neutral (like the
  -- status panel's HTML), so it needs no translation key.
  d:add_label(t("label.language"), 1, 15, 1, 1)
  w_lang = d:add_dropdown(2, 15, 2, 1)
  w_lang:add_value(LOCALE_LABELS[LANG], lang_index(LANG))   -- current first => shown selected
  for i, code in ipairs(LOCALES) do
    if code ~= LANG then w_lang:add_value(LOCALE_LABELS[code], i) end
  end
  d:add_button("✓", change_language, 4, 15, 1, 1)

  refresh_next_field()
  refresh_list()
  refresh_buttons()
  d:show()
  if out_path_is_fallback then
    set_status(t("activate.fallback"))
  elseif #rows > 0 then
    set_status(t("activate.resumed", { count = #rows, n = next_rally_number() }))
  else
    set_status(t("activate.ready"))
  end
end

-- Apply the language picker: read it, persist it, and rebuild the dialog in the new
-- language. Defined after create_dialog so it can call it (the dialog is recreated, like a
-- reason/sport rebuild but for the whole grid); module state (rows/mode/out_path) persists.
function change_language()
  if not w_lang then return end
  local id = w_lang:get_value()
  local code = LOCALES[id]
  if not code or not STRINGS[code] or code == LANG then return end
  LANG = code
  save_lang()
  if d then d:delete(); d = nil end
  w_reason = nil
  w_help = nil
  create_dialog()
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------
function activate()
  -- Build the id lookups here (full Lua environment), not at top level (see note
  -- where REASON_ID/SPORT_ID are declared -- the descriptor scan sandbox lacks ipairs).
  for i, v in ipairs(REASONS) do REASON_ID[v] = i end
  for i, v in ipairs(SPORTS) do SPORT_ID[v] = i end
  load_lang()             -- restore the saved language before building the dialog
  mode = "new"
  edit_index = nil
  w_help = nil
  w_reason = nil          -- niled so the first rebuild on a re-enable doesn't del a stale handle
  out_path = resolve_out_path()
  out_path_is_fallback = (current_media_path() == nil)   -- no video yet -> adopt its CSV lazily on first Mark
  load_rows()             -- continue an existing CSV (numbering + recent list)
  create_dialog()
end

function deactivate()
  if d then d:delete(); d = nil end
  w_help = nil
end

function close()
  deactivate()
  vlc.deactivate()
end
