--[[ dialog_test.lua -- headless tests for vlc/rally_annotator.lua

  The extension is a single Lua file that only talks to VLC through the global
  `vlc` table. This test STUBS that table (dialog widgets + playback) in pure Lua,
  loads the real extension, drives its callbacks, and asserts the resulting state.
  It cannot exercise VLC's actual GUI rendering, but it covers all the dialog LOGIC
  (mark/save/edit/delete/undo, reason reset, Next-# numbering, help toggle, and the
  playback controls) plus a LAYOUT SNAPSHOT of the whole widget grid + window title
  (diffed against test/dialog_layout.snapshot), and catches regressions before VLC.

  Run (needs Lua 5.1, matching VLC 3.x's embedded interpreter):
      lua5.1 test/dialog_test.lua            # from the repo root; exit 0 = pass, 1 = fail
      lua5.1 test/dialog_test.lua --update   # regenerate the layout snapshot golden
]]

-- Resolve the extension path relative to this test file, so it runs from anywhere.
local here = (arg and arg[0] and arg[0]:match("^(.*[/\\])")) or "./"
local EXT  = here .. "../vlc/rally_annotator.lua"

-- Redirect the CSV the extension writes to a temp dir, and start clean.
local TMP = os.getenv("TMPDIR") or os.getenv("TEMP") or "/tmp"
local _getenv = os.getenv
os.getenv = function(k) if k == "HOME" or k == "USERPROFILE" then return TMP end return _getenv(k) end
local sep = TMP:find("\\") and "\\" or "/"
local CSV = (TMP:sub(-1) == sep and TMP or TMP .. sep) .. "rally_labels.csv"
os.remove(CSV)

--------------------------------------------------------------------------------
-- Minimal stub of VLC's dialog/widget + playback API
--------------------------------------------------------------------------------
local function new_widget(kind, col, row, width, height)
  local w = { kind = kind, col = col, row = row, width = width or 1, height = height or 1,
              text = nil, values = {}, selection = {}, deleted = false }
  function w:set_text(t) self.text = t end
  function w:get_text() return self.text end
  function w:add_value(t, id) self.values[#self.values+1] = {id=id, text=t}; if #self.values==1 then self.sel_id=id; self.sel_text=t end end
  function w:get_value() return self.sel_id, self.sel_text end
  function w:clear() self.values = {}; self.sel_id = nil; self.sel_text = nil end
  function w:get_selection() return self.selection end
  return w
end

local DIALOG
local function new_dialog(title)
  local d = { title = title, widgets = {}, updates = 0 }
  function d:add_label(t,c,r,cs,rs) local w=new_widget('label',c,r,cs,rs); w.text=t; self.widgets[#self.widgets+1]=w; return w end
  function d:add_button(t,cb,c,r,cs,rs) local w=new_widget('button',c,r,cs,rs); w.text=t; w.cb=cb; self.widgets[#self.widgets+1]=w; return w end
  function d:add_dropdown(c,r,cs,rs) local w=new_widget('dropdown',c,r,cs,rs); self.widgets[#self.widgets+1]=w; return w end
  function d:add_list(c,r,cs,rs) local w=new_widget('list',c,r,cs,rs); self.widgets[#self.widgets+1]=w; return w end
  function d:add_text_input(t,c,r,cs,rs) local w=new_widget('text_input',c,r,cs,rs); w.text=(type(t)=='string') and t or ''; self.widgets[#self.widgets+1]=w; return w end
  function d:add_html(t,c,r,cs,rs) local w=new_widget('html',c,r,cs,rs); w.text=t; self.widgets[#self.widgets+1]=w; return w end
  function d:del_widget(w) w.deleted=true end
  function d:show() end
  function d:update() self.updates = self.updates + 1 end
  function d:delete() end
  function d:set_title(t) self.title=t end
  return d
end

-- playback state machine (mirrors VLC 3.x: pause() is a toggle)
local PB = { state = "stopped", time_us = 0 }
-- Currently-loaded media URI, or nil for "no media" (the default, so existing tests keep
-- resolving the CSV to the HOME fallback). Set MEDIA_URI to simulate a loaded video.
MEDIA_URI = nil
vlc = {
  dialog   = function(t) DIALOG = new_dialog(t); return DIALOG end,
  object   = { input = function() return (PB.state ~= "stopped") and { kind = "input" } or nil end },
  var      = {
    get = function(_, name) if name == "time" then return PB.time_us end return nil end,
    set = function(_, name, val) if name == "time" then PB.time_us = val end end,
  },
  input    = { item = function() return MEDIA_URI and { uri = function() return MEDIA_URI end } or nil end },
  playlist = {
    status = function() return PB.state end,
    play   = function() PB.state = "playing" end,
    pause  = function() if PB.state == "playing" then PB.state = "paused" elseif PB.state == "paused" then PB.state = "playing" end end,
    stop   = function() PB.state = "stopped" end,
  },
  deactivate = function() end,
  msg = { dbg=function() end, warn=function() end, err=function() end, info=function() end },
}

--------------------------------------------------------------------------------
-- Assertions
--------------------------------------------------------------------------------
local pass, fail = 0, 0
local function eq(name, got, want)
  if tostring(got) == tostring(want) then pass = pass + 1
  else fail = fail + 1; print(string.format("  FAIL  %s\n          got =%s\n          want=%s", name, tostring(got), tostring(want))) end
end
local function ok(name, cond) eq(name, cond and true or false, true) end

--------------------------------------------------------------------------------
-- Load the extension and build the dialog
--------------------------------------------------------------------------------
dofile(EXT)
ok("descriptor() returns a title", descriptor().title ~= nil)
eq("descriptor version", descriptor().version, "1.7.1")
-- the title carries the version so VLC's "Active Extensions" list (which shows the
-- title verbatim) displays it next to the plugin name -- and stays in sync, no drift.
eq("descriptor title carries the version", descriptor().title, "Rally Annotator v" .. descriptor().version)
activate()
local d = DIALOG
ok("dialog was created", d ~= nil)

-- the window title carries the version, and stays in sync with the descriptor (no drift)
ok("dialog title shows version", d.title:find("v" .. descriptor().version, 1, true) ~= nil)
eq("dialog title is exactly Name + version", d.title, "Rally Annotator v" .. descriptor().version)

--------------------------------------------------------------------------------
-- Layout snapshot -- the full widget grid + window title, diffed against a committed
-- golden (test/dialog_layout.snapshot). This is the deterministic, cross-platform
-- equivalent of a screenshot diff: VLC renders extension dialogs through Qt with no
-- headless/offscreen path, so we snapshot the widget tree the extension HANDS to VLC
-- (kind, grid column/row, column/row span, and the caption/options) instead of pixels.
-- Catches any moved, resized, renamed, added, or removed control, and any title change.
-- Runs here, right after activate(), while the dialog is in its pristine initial state
-- (no rows in the temp CSV, empty Start/End, help hidden) -- before any callback below
-- mutates the widget list. Regenerate intentionally with:
--     lua5.1 test/dialog_test.lua --update      (or UPDATE_SNAPSHOT=1)
--------------------------------------------------------------------------------
local function snap_caption(w)
  if w.kind == 'dropdown' then
    local opts = {}; for _, v in ipairs(w.values) do opts[#opts+1] = v.text end
    return '[' .. table.concat(opts, ', ') .. ']'           -- dropdown options (sports / reasons)
  elseif w.kind == 'html' then return '<runtime html>'      -- status/help body is dynamic content
  elseif w.kind == 'list' then return '<list>'              -- recent-rallies list (rows are data)
  elseif w.kind == 'text_input' then return string.format('%q', w.text or '')
  else return w.text or '' end                              -- label / button caption
end
local function render_snapshot()
  local lines = { 'title :: ' .. tostring(d.title) }
  local i = 0
  for _, w in ipairs(d.widgets) do
    if not w.deleted then
      i = i + 1
      lines[#lines+1] = string.format('%2d. %-10s @(%d,%d) %dx%d :: %s',
        i, w.kind, w.col, w.row, w.width, w.height, snap_caption(w))
    end
  end
  return table.concat(lines, '\n') .. '\n'
end
local function split_lines(s) local t={}; for l in (s.."\n"):gmatch('(.-)\n') do t[#t+1]=l end; return t end

local SNAP_FILE = here .. 'dialog_layout.snapshot'
local snap_got  = render_snapshot()
local snap_update = os.getenv('UPDATE_SNAPSHOT') == '1' or (arg and arg[1] == '--update')
if snap_update then
  local f = assert(io.open(SNAP_FILE, 'w')); f:write(snap_got); f:close()
  print('  (wrote layout snapshot: ' .. SNAP_FILE .. ')')
else
  local f = io.open(SNAP_FILE, 'r'); local snap_want = f and f:read('*a') or nil; if f then f:close() end
  if snap_want == nil then
    fail = fail + 1
    print('  FAIL  layout snapshot golden missing -- create it: lua5.1 test/dialog_test.lua --update')
  elseif snap_got == snap_want then
    pass = pass + 1
  else
    fail = fail + 1
    print('  FAIL  dialog layout/title differs from ' .. SNAP_FILE)
    local g, w = split_lines(snap_got), split_lines(snap_want)
    for k = 1, math.max(#g, #w) do
      if g[k] ~= w[k] then
        print(string.format('          want L%d: %s', k, w[k] or '<missing>'))
        print(string.format('          got  L%d: %s', k, g[k] or '<missing>'))
      end
    end
    print('        If this layout change is intentional, regenerate: lua5.1 test/dialog_test.lua --update')
  end
end

-- live (non-deleted) widget by grid position; reason dropdown is recreated on reset
local function find(kind, col, row)
  local f
  for _, w in ipairs(d.widgets) do if w.kind==kind and w.col==col and w.row==row and not w.deleted then f=w end end
  return f
end
local function buttonWithCb(cb) for _,w in ipairs(d.widgets) do if w.kind=='button' and w.cb==cb then return w end end end
local function pickReason(name)
  local w = find('dropdown', 3, 6)
  for _, v in ipairs(w.values) do if v.text==name then w.sel_id=v.id; w.sel_text=v.text; return end end
  error('reason option not found: '..name)
end
local function curReason() return (find('dropdown',3,6)).sel_text end
local function nextF()  return (find('text_input',2,4)):get_text() end
local function setNext(s) (find('text_input',2,4)):set_text(s) end
local function setS(s)  (find('text_input',2,3)):set_text(s) end
local function setE(s)  (find('text_input',4,3)):set_text(s) end
local function setShots(s) (find('text_input',4,4)):set_text(s) end
local function getShots()  return (find('text_input',4,4)):get_text() end

local helpBtn = buttonWithCb(show_help)
local statusHtml; for _, w in ipairs(d.widgets) do if w.kind=='html' then statusHtml=w; break end end
local function dedicatedHelp()
  local n=0; for _,w in ipairs(d.widgets) do if w.kind=='html' and w~=statusHtml and not w.deleted and w.text and w.text:find('how to use',1,true) then n=n+1 end end; return n
end

--------------------------------------------------------------------------------
-- Construction: all controls wired
--------------------------------------------------------------------------------
ok("Back 5s button wired",       buttonWithCb(seek_back) ~= nil)
ok("Play / Pause button wired",  buttonWithCb(play_pause) ~= nil)
ok("single playback toggle (no separate Resume/Pause globals)",
   _G.play_resume == nil and _G.pause_playback == nil)
ok("Fwd 5s button wired",        buttonWithCb(seek_fwd) ~= nil)
ok("Mark START button wired",    buttonWithCb(mark_start) ~= nil)
ok("Save Rally button wired",    buttonWithCb(save_rally) ~= nil)
ok("reason dropdown present",    find('dropdown',3,6) ~= nil)
ok("Number of shots input present", find('text_input',4,4) ~= nil)

--------------------------------------------------------------------------------
-- i18n: every locale defines EXACTLY the en key set (catches a missing/extra/typo'd key).
-- STRINGS is exposed as a global precisely so this parity gate can run headless.
--------------------------------------------------------------------------------
do
  ok("STRINGS table is exposed", type(STRINGS) == "table" and type(STRINGS.en) == "table")
  local enKeys, nEn = {}, 0
  for k in pairs(STRINGS.en) do enKeys[k] = true; nEn = nEn + 1 end
  for _, code in ipairs({ "kn", "hi", "te", "es", "da", "id" }) do
    local n, missing, extra = 0, nil, nil
    for k in pairs(STRINGS[code] or {}) do n = n + 1; if not enKeys[k] then extra = k end end
    for k in pairs(enKeys) do if not (STRINGS[code] or {})[k] then missing = k end end
    eq("i18n " .. code .. ": key count matches en (" .. nEn .. ")", n, nEn)
    ok("i18n " .. code .. ": no missing key vs en (" .. tostring(missing) .. ")", missing == nil)
    ok("i18n " .. code .. ": no extra key vs en (" .. tostring(extra) .. ")", extra == nil)
  end
end

--------------------------------------------------------------------------------
-- Help toggle (dedicated panel add/remove)
--------------------------------------------------------------------------------
eq("help hidden initially", dedicatedHelp(), 0)
show_help(); eq("help shows on 1st click", dedicatedHelp(), 1); eq("button says Hide help", helpBtn.text, "Hide help")
show_help(); eq("help hides on 2nd click", dedicatedHelp(), 0); eq("button says Help", helpBtn.text, "Help")
show_help(); eq("help shows again", dedicatedHelp(), 1)
show_help(); eq("help hides again", dedicatedHelp(), 0)

--------------------------------------------------------------------------------
-- Reason: default unknown, resets each save, consecutive identical reasons work
--------------------------------------------------------------------------------
eq("reason defaults to unknown", curReason(), "unknown")
setNext('1'); setS('1'); setE('2'); pickReason('winner'); setShots('12'); save_rally()
eq("reason resets to unknown after save A", curReason(), "unknown")
eq("shots field clears after save A", getShots(), "")          -- non-sticky like reason
eq("Next# auto-advances to 2", nextF(), "2")
setS('3'); setE('4'); pickReason('winner'); save_rally()        -- consecutive winner, no shots
eq("reason resets to unknown after save B", curReason(), "unknown")
setS('5'); setE('6'); save_rally()                              -- no pick -> unknown, no shots
eq("Next# at 4 after three saves", nextF(), "4")

--------------------------------------------------------------------------------
-- Next #: collision refused; undo of a committed row re-syncs Next#
--------------------------------------------------------------------------------
setNext('2'); setS('7'); setE('8'); pickReason('let'); save_rally()   -- #2 exists -> refuse
eq("duplicate #2 refused (Next# unchanged)", nextF(), "2")
setS(''); setE('')        -- clear in-progress so undo removes a row
setNext('99')             -- stale value
undo_last()               -- removes the last committed row (#3)
eq("undo re-syncs Next# to real next (3, not 99)", nextF(), "3")

--------------------------------------------------------------------------------
-- Verify the CSV the extension actually wrote (1=winner, 2=winner, 3 undone)
--------------------------------------------------------------------------------
local fh = io.open(CSV, "r"); local csv = fh and fh:read("*a") or ""; if fh then fh:close() end
ok("CSV has shots_count header", csv:find("rally_number,start_time,end_time,ending_reason,sport,shots_count", 1, true) ~= nil)
ok("CSV row #1 winner + shots=12", csv:find("\n1,1.000,2.000,winner,badminton,12\n", 1, true) ~= nil)
ok("CSV row #2 winner, shots column blank", csv:find("\n2,3.000,4.000,winner,badminton,\n", 1, true) ~= nil)
ok("CSV row #3 was undone (absent)", csv:find("\n3,", 1, true) == nil)
os.remove(CSV)

--------------------------------------------------------------------------------
-- Edit reloads the saved shots into the field; editing the count rewrites the CSV
--------------------------------------------------------------------------------
local lst = find('list', 1, 10)
lst.selection = { [1] = "row #1" }       -- select rally #1 in the Recent list
edit_selected()
eq("edit loads shots=12 into field", getShots(), "12")
eq("edit loads start time", (find('text_input',2,3)):get_text(), "1.000")
eq("edit loads reason winner", curReason(), "winner")
setShots('7'); save_rally()              -- change the count and commit
eq("shots field clears after edit-save", getShots(), "")
local fh2 = io.open(CSV, "r"); local csv2 = fh2 and fh2:read("*a") or ""; if fh2 then fh2:close() end
ok("edited shots persisted (#1 now 7)", csv2:find("\n1,1.000,2.000,winner,badminton,7\n", 1, true) ~= nil)
os.remove(CSV)

--------------------------------------------------------------------------------
-- Playback: one Play / Pause toggle branches on status() (playing<->paused), and
-- starts fresh from stopped. Seek is relative ±5s, clamped at 0.
--------------------------------------------------------------------------------
PB.state = "playing"; PB.time_us = 30 * 1000000
play_pause(); eq("Play/Pause while playing -> paused", PB.state, "paused")
play_pause(); eq("Play/Pause while paused -> playing", PB.state, "playing")
play_pause(); eq("Play/Pause toggles back to paused", PB.state, "paused")
seek_back();  eq("Back 5s from 30s -> 25s", PB.time_us, 25 * 1000000)
seek_fwd();   eq("Fwd 5s from 25s -> 30s", PB.time_us, 30 * 1000000)
PB.time_us = 2 * 1000000; seek_back(); eq("Back 5s from 2s clamps to 0", PB.time_us, 0)
PB.state = "stopped"; play_pause(); eq("Play/Pause from stopped -> playing", PB.state, "playing")

--------------------------------------------------------------------------------
-- Recent list shows EVERY rally, oldest first (regression: a "last 12" cap used to
-- hide the oldest rallies once there were 13+, so #1 was unselectable for Edit/Delete).
--------------------------------------------------------------------------------
do
  local f = io.open(CSV, "w")
  f:write("rally_number,start_time,end_time,ending_reason,sport,shots_count\n")
  for n = 1, 13 do f:write(string.format("%d,%d.000,%d.000,winner,badminton,\n", n, n, n + 1)) end
  f:close()
  activate()                                  -- rebuild the dialog + list from the 13-row CSV
  local L; for _, w in ipairs(DIALOG.widgets) do if w.kind == 'list' and not w.deleted then L = w end end
  ok("recent list present after reload", L ~= nil)
  eq("recent list shows all 13 rallies (no cap)", #L.values, 13)
  eq("oldest rally #1 is the first row", L.values[1] and L.values[1].text:match("^#(%d+)"), "1")
  eq("newest rally #13 is the last row", L.values[#L.values] and L.values[#L.values].text:match("^#(%d+)"), "13")
  os.remove(CSV)
end

--------------------------------------------------------------------------------
-- Data safety on resume: enabling the extension BEFORE the video loads used to write
-- rallies to ~/rally_labels.csv (the home fallback) and never reload the video's own CSV
-- on restart, so labels looked "lost". The moment a timestamp exists (video playing), the
-- first Mark START must adopt <video>.rallies.csv and load any rallies already saved for it.
--------------------------------------------------------------------------------
do
  local TMPb = (TMP:sub(-1) == sep) and TMP:sub(1, -2) or TMP
  local VIDEO_CSV = TMPb .. sep .. "clip.rallies.csv"
  os.remove(CSV); os.remove(VIDEO_CSV)
  local vf = io.open(VIDEO_CSV, "w")            -- a prior session already saved 2 rallies here
  vf:write("rally_number,start_time,end_time,ending_reason,sport,shots_count\n")
  vf:write("1,1.000,2.000,winner,badminton,\n")
  vf:write("2,3.000,4.000,let,badminton,\n")
  vf:close()

  MEDIA_URI = nil; PB.state = "stopped"          -- enable with NO video loaded -> home fallback
  activate()
  local D2 = DIALOG
  local function live(kind, c, r)
    local f; for _, w in ipairs(D2.widgets) do if w.kind==kind and w.col==c and w.row==r and not w.deleted then f=w end end; return f
  end
  local function nVals() local L; for _, w in ipairs(D2.widgets) do if w.kind=='list' and not w.deleted then L=w end end; return L and #L.values or -1 end
  eq("fallback start shows no video rallies", nVals(), 0)

  MEDIA_URI = "file://" .. TMPb .. sep .. "clip.mp4"; PB.state = "playing"; PB.time_us = 10 * 1000000
  mark_start()                                   -- video provably playing -> adopt clip.rallies.csv
  eq("Mark START adopts the video's 2 existing rallies", nVals(), 2)
  live('text_input', 4, 3):set_text("11")        -- End (s); Start was set to 10.000 by mark_start
  save_rally()
  local hv = io.open(VIDEO_CSV, "r"); local vcsv = hv and hv:read("*a") or ""; if hv then hv:close() end
  ok("new rally #3 written to <video>.rallies.csv", vcsv:find("\n3,", 1, true) ~= nil)
  local hh = io.open(CSV, "r"); local home = hh and hh:read("*a") or ""; if hh then hh:close() end
  ok("home fallback CSV was never written", home == "")
  MEDIA_URI = nil; os.remove(VIDEO_CSV); os.remove(CSV)
end

--------------------------------------------------------------------------------
-- Guard: a fully-marked-but-unsaved rally (START + END) must not be silently lost when
-- the user starts a new rally (Mark START) or jumps to editing another (Edit selected).
--------------------------------------------------------------------------------
do
  os.remove(CSV)
  MEDIA_URI = nil; PB.state = "playing"; PB.time_us = 200 * 1000000
  activate()
  local function win(kind, c, r) local f; for _, x in ipairs(DIALOG.widgets) do if x.kind==kind and x.col==c and x.row==r and not x.deleted then f=x end end; return f end
  local function listw() local L; for _, x in ipairs(DIALOG.widgets) do if x.kind=='list' and not x.deleted then L=x end end; return L end

  -- save one rally so the Recent list has a row to (attempt to) edit
  win('text_input',2,3):set_text("1.000"); win('text_input',4,3):set_text("2.000"); save_rally()
  -- arm a fresh rally: START + END filled, unsaved
  win('text_input',2,3):set_text("100.000"); win('text_input',4,3):set_text("110.000")

  mark_start()   -- would overwrite START to 200.000 -> must be REFUSED, fields untouched
  eq("armed: Mark START refused (START unchanged)", win('text_input',2,3):get_text(), "100.000")
  eq("armed: still a new rally (not pushed to edit)", win('text_input',4,3):get_text(), "110.000")

  listw().selection = { [1] = "row #1" }
  edit_selected() -- would load #1 over the armed marks -> must be REFUSED
  eq("armed: Edit selected refused (START still the armed 100.000)", win('text_input',2,3):get_text(), "100.000")

  undo_last()     -- the documented escape hatch: clears the in-progress mark
  eq("after Undo last, START cleared", win('text_input',2,3):get_text(), "")
  mark_start()    -- no longer armed -> now allowed
  eq("after clearing, Mark START works (200.000)", win('text_input',2,3):get_text(), "200.000")
  os.remove(CSV)
end

--------------------------------------------------------------------------------
-- Edit-mode prominence: the Mark buttons relabel to "Re-mark START/END (#N)" so it is
-- obvious they change the EDITED rally, not a new one; they revert when the edit ends.
--------------------------------------------------------------------------------
do
  os.remove(CSV)
  MEDIA_URI = nil; PB.state = "stopped"
  activate()
  local function markBtn(cb) for _, x in ipairs(DIALOG.widgets) do if x.kind=='button' and x.cb==cb and not x.deleted then return x end end end
  local function w23(c,r) local f; for _, x in ipairs(DIALOG.widgets) do if x.kind=='text_input' and x.col==c and x.row==r and not x.deleted then f=x end end; return f end
  local function listw() local L; for _, x in ipairs(DIALOG.widgets) do if x.kind=='list' and not x.deleted then L=x end end; return L end

  w23(2,3):set_text("1.000"); w23(4,3):set_text("2.000"); save_rally()
  eq("pristine Mark START label", markBtn(mark_start).text, "Mark START")
  eq("pristine Mark END label",   markBtn(mark_end).text,   "Mark END")

  listw().selection = { [1] = "row #1" }
  edit_selected()
  eq("editing relabels Mark START", markBtn(mark_start).text, "Re-mark START (#1)")
  eq("editing relabels Mark END",   markBtn(mark_end).text,   "Re-mark END (#1)")

  undo_last()   -- cancels the edit
  eq("after cancel Mark START label restored", markBtn(mark_start).text, "Mark START")
  eq("after cancel Mark END label restored",   markBtn(mark_end).text,   "Mark END")
  os.remove(CSV)
end

--------------------------------------------------------------------------------
-- Language switch: picking a locale + change_language() rebuilds the dialog localized;
-- switching back restores English. (The CSV stays canonical regardless -- the save path
-- maps the selected dropdown id back to the canonical value, exercised above.)
--------------------------------------------------------------------------------
do
  local LANGCFG = (TMP:sub(-1) == sep and TMP or TMP .. sep) .. ".rally_annotator_lang"
  os.remove(LANGCFG); os.remove(CSV)
  MEDIA_URI = nil; PB.state = "stopped"
  activate()
  local function lbl(c, r) for _, w in ipairs(DIALOG.widgets) do if w.kind=='label' and w.col==c and w.row==r and not w.deleted then return w end end end
  local function langDrop() for _, w in ipairs(DIALOG.widgets) do if w.kind=='dropdown' and w.col==2 and w.row==15 and not w.deleted then return w end end end
  eq("sport label English before switch", lbl(1,1) and lbl(1,1).text, "Sport:")
  ok("language dropdown present at (2,15)", langDrop() ~= nil)
  langDrop().sel_id = 2            -- kn = LOCALES[2]
  change_language()
  ok("sport label localized (non-English) after switch to kn", lbl(1,1) ~= nil and lbl(1,1).text ~= "Sport:")
  langDrop().sel_id = 1            -- en = LOCALES[1]
  change_language()
  eq("sport label English again after switch back", lbl(1,1) and lbl(1,1).text, "Sport:")
  os.remove(LANGCFG); os.remove(CSV)
end

--------------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
