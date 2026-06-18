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
local VERSION = "1.6.4"

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

-- In-dialog help (rendered into the status panel by the HELP button). Basic HTML
-- only (<b>, <i>, <br>) for portability across the Qt and macOS dialog renderers.
local HELP_HTML = [==[
<b>Rally Annotator &mdash; how to use</b><br>
<b>Playback:</b> the <b>Back 5s / Play / Pause / Fwd 5s</b> row drives the VLC player from here &mdash; <b>Play / Pause</b> is one toggle (pause, annotate, and resume without switching to the main VLC window).<br>
1. Pick the <b>Sport</b> (top). It stays set across rallies.<br>
2. When a rally begins, click <b>Mark START</b> (pause/scrub first for frame accuracy &mdash; it snapshots the current playback time into the Start field).<br>
3. When the rally ends, click <b>Mark END</b>. You may fine-tune the Start/End seconds by editing those fields directly.<br>
4. Choose the <b>Ending reason</b> (the box between <b>Mark END</b> and <b>Save Rally</b>; or leave it as <b>unknown</b>), optionally type a <b>Number of shots</b> (the rally's shot/stroke count &mdash; leave blank to skip), then click <b>Save Rally</b> &mdash; one CSV row is written next to the video.<br>
5. The reason RESETS to <b>unknown</b> after every save (never silently reused), and you can pick the same reason on consecutive rallies.<br>
6. <b>Recent rallies</b>: select a row, then <b>Edit selected</b> (loads it back into the fields) or <b>Delete selected</b>. <b>Undo last</b> removes the most recent row (the button shows which, e.g. <i>Undo last (#7)</i>), or clears an in-progress mark, or cancels an edit.<br>
7. <b>Resuming later:</b> labels are saved to the CSV next to the video as you go. Re-open the SAME video and enable the extension &mdash; it reloads your existing rallies and continues numbering. Set the <b>Next rally #</b> field to resume numbering from any value (e.g. restart at 1, or continue from 50); it auto-advances after each save. If you switch videos with this dialog open, click <b>Refresh</b> to load the current video's rallies. (The video's playback position is not restored &mdash; scrub to where you stopped.)<br>
<br>
<b>Ending reasons &mdash; what they mean (pick the one that says WHY the rally ended).</b><br>
All reasons except <i>winner</i> are charged to the side that LOST the rally.<br>
&bull; <b>winner</b> &mdash; the last shot landed IN and was not returned (opponent couldn't reach it, or only waved at it). A clean untouched serve (ace) counts here.<br>
&bull; <b>forced_error</b> &mdash; the loser MISSED (out, or into the net) while UNDER PRESSURE: stretched, rushed, jammed, or handling the opponent's pace/spin/depth. They were made to miss.<br>
&bull; <b>unforced_error</b> &mdash; the loser MISSED a routine shot they had time AND position to make, with little or no pressure. They gave it away.<br>
&bull; <b>service_fault</b> &mdash; the point ended on the SERVE: serve into the net, out of the service box, illegal action/foot fault, or a double fault (tennis/padel).<br>
&bull; <b>let</b> &mdash; the rally is REPLAYED under the rules (no point): e.g. a tennis/table-tennis serve that clips the net and is otherwise good, or outside interference.<br>
&bull; <b>other</b> &mdash; anything else (occluded footage, injury/retirement, penalty, hindrance). Use sparingly.<br>
&bull; <b>unknown</b> &mdash; the default; this rally hasn't been classified yet (pick a specific reason when you can).<br>
<br>
<b>Quick cases</b><br>
&bull; Ball/shuttle lands <b>OUT</b> (past the baseline / outside the lines): it is the hitter's miss &mdash; <b>forced</b> if they were under pressure, <b>unforced</b> if it was a comfortable ball. (OUT is NOT automatically forced, and never a winner for the opponent.)<br>
&bull; <b>Into the net</b> during a rally: same &mdash; forced if pressured, unforced if routine. A <b>serve</b> into the net is <b>service_fault</b>.<br>
&bull; <b>Net-cord that dribbles over and lands in</b>: live and good &mdash; usually a <b>winner</b> if unreachable, else judge what happens next. On the SERVE it varies by sport: tennis/table-tennis = <b>let</b> (replay); badminton net-tick that passes over and lands in = play on (but a serve shuttle CAUGHT on the net = service_fault); pickleball (2026) = play on.<br>
&bull; <b>Unsure forced vs unforced?</b> Default to <b>unforced</b> &mdash; only mark forced when you can point to the specific pressure.<br>
<br>
Output: <i>&lt;video&gt;.rallies.csv</i> next to the video. Full guide: docs/ENDING_REASONS.md in the repo.<br>
Click <b>Hide help</b> to return to the status panel.
]==]

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
  w_reason:add_value(REASON_DEFAULT, 0)            -- "unknown" default (id 0)
  for i, v in ipairs(REASONS) do w_reason:add_value(v, i) end
end

local function rebuild_reason_selected(sel)
  if not d then return end
  if not sel or sel == "" then sel = REASON_DEFAULT end
  if w_reason then d:del_widget(w_reason) end
  w_reason = d:add_dropdown(3, 6, 1, 1)
  w_reason:add_value(sel, REASON_ID[sel] or 0)     -- selected first
  if sel ~= REASON_DEFAULT then w_reason:add_value(REASON_DEFAULT, 0) end
  for i, v in ipairs(REASONS) do
    if v ~= sel then w_reason:add_value(v, i) end
  end
end

local function rebuild_sport_selected(sel)
  if not w_sport then return end
  if not sel or sel == "" then sel = SPORTS[1] end
  w_sport:clear()
  local id = SPORT_ID[sel] or 99
  w_sport:add_value(sel, id)                        -- first => shown selected
  for i, v in ipairs(SPORTS) do
    if v ~= sel then w_sport:add_value(v, i) end
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
    local label = string.format("#%d   %s -> %s   [%s, %s]", r.n, fmt_clock(r.s), fmt_clock(r.e), r.reason, r.sport)
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
      w_save:set_text(string.format("Save changes (#%d)", rows[edit_index].n))
    else
      local s = get_field_num(w_start)
      local e = get_field_num(w_end)
      if s and e then
        w_save:set_text(string.format("Save Rally (#%d)", planned_next_number()))
      else
        w_save:set_text("Save Rally")
      end
    end
  end
  -- While editing, the Mark buttons re-mark the EDITED rally's times (not a new one),
  -- so relabel them to make that unmissable -- a forgotten edit-mode is how you'd
  -- accidentally overwrite an existing rally thinking you were creating a new one.
  if w_mark_start and w_mark_end then
    if mode == "edit" and edit_index and rows[edit_index] then
      w_mark_start:set_text(string.format("Re-mark START (#%d)", rows[edit_index].n))
      w_mark_end:set_text(string.format("Re-mark END (#%d)", rows[edit_index].n))
    else
      w_mark_start:set_text("Mark START")
      w_mark_end:set_text("Mark END")
    end
  end
  if w_undo then
    if mode == "edit" then
      w_undo:set_text("Undo last (cancel edit)")
    else
      local s = get_field_num(w_start)
      local e = get_field_num(w_end)
      if s or e then
        w_undo:set_text("Undo last (clear mark)")
      elseif #rows > 0 then
        w_undo:set_text(string.format("Undo last (#%d)", rows[#rows].n))
      else
        w_undo:set_text("Undo last")
      end
    end
  end
  if d then d:update() end
end

local function set_status(msg)
  if not w_status then return end
  local mode_line
  if mode == "edit" and edit_index and rows[edit_index] then
    mode_line = string.format(
      "Mode: EDITING rally #%d  (Save changes to commit, Undo last to cancel).", rows[edit_index].n)
  else
    mode_line = "Mode: new rally  (Mark START, Mark END, choose reason, Save Rally)."
  end
  local last_line = ""
  if #rows > 0 then
    local lr = rows[#rows]
    last_line = string.format("Last row (what Undo removes): #%d  %s -&gt; %s  [%s]<br>",
      lr.n, esc(fmt_clock(lr.s)), esc(fmt_clock(lr.e)), esc(lr.reason))
  end
  w_status:set_text(string.format(
    "%s<br>%s<br>%sNow: %s &nbsp;|&nbsp; Rallies in CSV: %d<br>CSV: %s",
    esc(msg), esc(mode_line), last_line, esc(fmt_clock(now_seconds())), #rows, esc(out_path)))
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
    set_status("Finish (Save changes) or cancel (Undo last) the current edit before refreshing.")
    return
  end
  local media = current_media_path()
  if not media then
    refresh_list(); refresh_buttons()
    set_status("No media is playing -- still using this CSV. Open the video, then click Refresh.")
    return
  end
  out_path_is_fallback = false   -- a video is playing now -> we have a real path
  local new_path = resolve_out_path()
  if new_path == out_path then
    load_rows()                  -- re-read in case the file changed on disk
    refresh_next_field()
    refresh_list(); refresh_buttons()
    set_status(string.format("Refreshed. %d rallies loaded for this video.", #rows))
    return
  end
  out_path = new_path            -- switched videos -> repoint + resume that file
  load_rows()
  reset_form()
  refresh_next_field()
  refresh_list()
  refresh_buttons()
  set_status(string.format(
    "Switched to the current video. Loaded %d existing rallies; next is #%d.", #rows, next_rally_number()))
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
  if not input then set_status("No media playing -- cannot seek."); return end
  local t = vlc.var.get(input, "time")   -- microseconds
  if not t then set_status("No playback time available to seek from."); return end
  local nt = t + delta_s * 1000000
  if nt < 0 then nt = 0 end
  vlc.var.set(input, "time", nt)
  set_status(string.format("Seek %+ds  ->  %s.", delta_s, fmt_clock(nt / 1000000.0)))
end

--------------------------------------------------------------------------------
-- Button callbacks (VLC calls these on its main loop; kept global to be safe)
--------------------------------------------------------------------------------
function mark_start()
  local t = now_seconds()
  if not t then set_status("No media playing -- cannot mark START."); return end
  if is_armed() then
    set_status("You have an UNSAVED rally (START -> END). Click 'Save Rally' to keep it, or 'Undo last' to "
      .. "clear it, before marking a new START. (You can also edit the Start field by hand.)")
    return
  end
  adopt_current_video_csv()   -- video is playing now: make sure we're on its CSV, not the fallback
  w_start:set_text(string.format("%.3f", t))
  refresh_buttons()
  set_status(string.format("START set @ %s. Play to the rally's end, then Mark END.", fmt_clock(t)))
end

function mark_end()
  local t = now_seconds()
  if not t then set_status("No media playing -- cannot mark END."); return end
  w_end:set_text(string.format("%.3f", t))
  refresh_buttons()
  set_status(string.format("END set @ %s. Choose the Ending reason, then click Save Rally.", fmt_clock(t)))
end

function save_rally()
  adopt_current_video_csv()   -- in case times were typed by hand without Mark START
  local s = get_field_num(w_start)
  local e = get_field_num(w_end)
  if not s then set_status("Set a START time first (click Mark START)."); return end
  if not e then set_status("Set an END time first (click Mark END)."); return end
  if e < s then s, e = e, s end   -- tolerate reversed marks
  if e <= s then
    set_status("END must be later than START (rally must be > 0s).")
    return
  end
  local _, reason = w_reason:get_value()   -- (id, text); "unknown" is allowed
  if not reason or reason == "" then reason = REASON_DEFAULT end
  local _, sport = w_sport:get_value()
  if not sport or sport == "" then sport = SPORTS[1] end
  local shots = get_shots()                -- optional; nil when blank
  local shots_note = (shots ~= nil) and string.format(", %d shots", shots) or ""

  local msg
  if mode == "edit" and edit_index and rows[edit_index] then
    local r = rows[edit_index]
    r.s, r.e, r.reason, r.sport, r.shots = s, e, reason, sport, shots
    local ok, err = save_all()
    if not ok then set_status("WRITE FAILED: " .. tostring(err)); return end
    msg = string.format("Updated rally #%d: %s -> %s  [%s, %s%s].", r.n, fmt_clock(s), fmt_clock(e), reason, sport, shots_note)
  else
    local n = planned_next_number()
    if index_of_rally(n) then
      set_status(string.format("Rally #%d already exists -- set \"Next rally #\" to a free number.", n))
      return
    end
    rows[#rows + 1] = { n = n, s = s, e = e, reason = reason, sport = sport, shots = shots }
    local ok, err = save_all()
    if not ok then rows[#rows] = nil; set_status("WRITE FAILED: " .. tostring(err)); return end
    if w_next then w_next:set_text(tostring(next_free_from(n + 1))) end   -- next free number
    msg = string.format("Saved rally #%d: %s -> %s  [%s, %s%s].", n, fmt_clock(s), fmt_clock(e), reason, sport, shots_note)
  end

  reset_form()       -- clears fields + resets the (required) reason to placeholder
  refresh_list()
  set_status(msg)
end

function edit_selected()
  if is_armed() then
    set_status("Finish the current rally ('Save Rally') or clear it ('Undo last') before editing another "
      .. "-- your unsaved START -> END would be lost.")
    return
  end
  local n = selected_rally_number()
  if not n then set_status("Pick a rally in the Recent list first, then Edit selected."); return end
  local idx = index_of_rally(n)
  if not idx then set_status("Rally #" .. tostring(n) .. " not found (try Refresh)."); return end
  local r = rows[idx]
  mode = "edit"; edit_index = idx
  w_start:set_text(string.format("%.3f", r.s))
  w_end:set_text(string.format("%.3f", r.e))
  if w_shots then w_shots:set_text(r.shots ~= nil and tostring(r.shots) or "") end
  rebuild_reason_selected(r.reason)
  rebuild_sport_selected(r.sport)
  refresh_buttons()
  set_status(string.format(
    "Editing rally #%d. Adjust Start/End/reason, then Save changes. (Undo last cancels.)", r.n))
end

function delete_selected()
  local n = selected_rally_number()
  if not n then set_status("Pick a rally in the Recent list first, then Delete selected."); return end
  local idx = index_of_rally(n)
  if not idx then set_status("Rally #" .. tostring(n) .. " not found (try Refresh)."); return end
  table.remove(rows, idx)
  local ok, err = save_all()
  if not ok then set_status("WRITE FAILED: " .. tostring(err)); return end
  reset_form()
  refresh_next_field()
  refresh_list()
  set_status(string.format("Deleted rally #%d. %d remaining.", n, #rows))
end

function undo_last()
  if mode == "edit" then
    reset_form(); refresh_list(); set_status("Edit cancelled.")
    return
  end
  local s = get_field_num(w_start)
  local e = get_field_num(w_end)
  if s or e then
    reset_form()
    set_status("Cleared the in-progress START/END (nothing was written).")
    return
  end
  if #rows == 0 then set_status("Nothing to undo."); return end
  local last = rows[#rows]
  rows[#rows] = nil
  local ok, err = save_all()
  if not ok then rows[#rows + 1] = last; set_status("WRITE FAILED: " .. tostring(err)); return end
  refresh_list()
  refresh_next_field()
  refresh_buttons()
  set_status(string.format("Removed last rally #%d. %d remaining.", last.n, #rows))
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
    set_status("Paused. Annotate (or fine-tune Start/End), then Play / Pause to resume.")
  elseif st == "paused" then
    vlc.playlist.pause()        -- toggles paused -> playing
    set_status("Resumed playback.")
  elseif st == "stopped" then
    vlc.playlist.play()
    set_status("Started playback.")
  else
    set_status("No media loaded to play.")
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
    if w_help_btn then w_help_btn:set_text("Help") end
  else
    if d then w_help = d:add_html(HELP_HTML, 1, 16, 4, 8) end
    if w_help_btn then w_help_btn:set_text("Hide help") end
  end
  if d then d:update() end
end

--------------------------------------------------------------------------------
-- Dialog construction
--------------------------------------------------------------------------------
local function create_dialog()
  d = vlc.dialog("Rally Annotator v" .. VERSION)

  d:add_label("Sport:", 1, 1, 1, 1)
  w_sport = d:add_dropdown(2, 1, 2, 1)
  for i, v in ipairs(SPORTS) do w_sport:add_value(v, i) end   -- badminton first => default
  w_help_btn = d:add_button("Help", show_help, 4, 1, 1, 1)

  -- Playback controls -- one row of 3: Back 5s | Play / Pause (toggle) | Fwd 5s.
  d:add_button("Back 5s",      seek_back,  1, 2, 1, 1)
  d:add_button("Play / Pause", play_pause, 2, 2, 2, 1)   -- spans cols 2-3, centered
  d:add_button("Fwd 5s",       seek_fwd,   4, 2, 1, 1)

  d:add_label("Start (s):", 1, 3, 1, 1)
  w_start = d:add_text_input("", 2, 3, 1, 1)
  d:add_label("End (s):", 3, 3, 1, 1)
  w_end = d:add_text_input("", 4, 3, 1, 1)

  d:add_label("Next rally #:", 1, 4, 1, 1)
  w_next = d:add_text_input("", 2, 4, 1, 1)
  d:add_label("Number of shots:", 3, 4, 1, 1)   -- optional; blank => shots_count left empty
  w_shots = d:add_text_input("", 4, 4, 1, 1)

  d:add_label("Ending reason:", 3, 5, 1, 1)   -- labels the reason dropdown directly below it

  -- Per-rally commit row, left-to-right: Mark START -> Mark END -> reason -> Save.
  w_mark_start = d:add_button("Mark START", mark_start, 1, 6, 1, 1)
  w_mark_end   = d:add_button("Mark END",   mark_end,   2, 6, 1, 1)
  rebuild_reason_default()                     -- creates w_reason at (3,6,1,1), under its label
  w_save = d:add_button("Save Rally", save_rally, 4, 6, 1, 1)

  w_status = d:add_html("", 1, 7, 4, 2)   -- rich-text status panel (multi-line via <br>)

  d:add_label("Recent rallies (select one, then Edit/Delete):", 1, 9, 4, 1)
  w_list = d:add_list(1, 10, 4, 4)

  d:add_button("Edit selected",   edit_selected,   1, 14, 1, 1)
  d:add_button("Delete selected", delete_selected, 2, 14, 1, 1)
  w_undo = d:add_button("Undo last", undo_last,     3, 14, 1, 1)
  d:add_button("Refresh",         refresh_now,     4, 14, 1, 1)

  refresh_next_field()
  refresh_list()
  refresh_buttons()
  d:show()
  if out_path_is_fallback then
    set_status("No video detected yet. Open/play the video, then click Mark START -- the tool will switch to "
      .. "that video's own .rallies.csv automatically (and load any rallies already saved for it). "
      .. "Tip: open the video FIRST, then enable this extension.")
  elseif #rows > 0 then
    set_status(string.format(
      "Resumed this video: %d existing rallies loaded (next is #%d). Click Help for the guide.",
      #rows, next_rally_number()))
  else
    set_status("Ready. Pick the Sport, then mark rallies. Click Help for usage + the ending-reason guide.")
  end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------
function activate()
  -- Build the id lookups here (full Lua environment), not at top level (see note
  -- where REASON_ID/SPORT_ID are declared -- the descriptor scan sandbox lacks ipairs).
  for i, v in ipairs(REASONS) do REASON_ID[v] = i end
  for i, v in ipairs(SPORTS) do SPORT_ID[v] = i end
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
