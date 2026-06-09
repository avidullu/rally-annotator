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
vlc = {
  dialog   = function(t) DIALOG = new_dialog(t); return DIALOG end,
  object   = { input = function() return (PB.state ~= "stopped") and { kind = "input" } or nil end },
  var      = {
    get = function(_, name) if name == "time" then return PB.time_us end return nil end,
    set = function(_, name, val) if name == "time" then PB.time_us = val end end,
  },
  input    = { item = function() return nil end },
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
eq("descriptor version", descriptor().version, "1.5.1")
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
  local w = find('dropdown', 3, 5)
  for _, v in ipairs(w.values) do if v.text==name then w.sel_id=v.id; w.sel_text=v.text; return end end
  error('reason option not found: '..name)
end
local function curReason() return (find('dropdown',3,5)).sel_text end
local function nextF()  return (find('text_input',2,4)):get_text() end
local function setNext(s) (find('text_input',2,4)):set_text(s) end
local function setS(s)  (find('text_input',2,3)):set_text(s) end
local function setE(s)  (find('text_input',4,3)):set_text(s) end

local helpBtn = buttonWithCb(show_help)
local statusHtml; for _, w in ipairs(d.widgets) do if w.kind=='html' then statusHtml=w; break end end
local function dedicatedHelp()
  local n=0; for _,w in ipairs(d.widgets) do if w.kind=='html' and w~=statusHtml and not w.deleted and w.text and w.text:find('how to use',1,true) then n=n+1 end end; return n
end

--------------------------------------------------------------------------------
-- Construction: all controls wired
--------------------------------------------------------------------------------
ok("Back 5s button wired",       buttonWithCb(seek_back) ~= nil)
ok("Play / Resume button wired", buttonWithCb(play_resume) ~= nil)
ok("Pause button wired",         buttonWithCb(pause_playback) ~= nil)
ok("Fwd 5s button wired",        buttonWithCb(seek_fwd) ~= nil)
ok("Mark START button wired",    buttonWithCb(mark_start) ~= nil)
ok("Save Rally button wired",    buttonWithCb(save_rally) ~= nil)
ok("reason dropdown present",    find('dropdown',3,5) ~= nil)

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
setNext('1'); setS('1'); setE('2'); pickReason('winner'); save_rally()
eq("reason resets to unknown after save A", curReason(), "unknown")
eq("Next# auto-advances to 2", nextF(), "2")
setS('3'); setE('4'); pickReason('winner'); save_rally()        -- consecutive winner
eq("reason resets to unknown after save B", curReason(), "unknown")
setS('5'); setE('6'); save_rally()                              -- no pick -> unknown
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
ok("CSV has header", csv:find("rally_number,start_time,end_time,ending_reason,sport", 1, true) ~= nil)
ok("CSV row #1 winner", csv:find("\n1,1.000,2.000,winner,", 1, true) ~= nil)
ok("CSV row #2 winner (consecutive)", csv:find("\n2,3.000,4.000,winner,", 1, true) ~= nil)
ok("CSV row #3 was undone (absent)", csv:find("\n3,", 1, true) == nil)
os.remove(CSV)

--------------------------------------------------------------------------------
-- Playback: pause()/play() are gated on status() so Pause and Resume are deterministic
--------------------------------------------------------------------------------
PB.state = "playing"; PB.time_us = 30 * 1000000
pause_playback(); eq("Pause while playing -> paused", PB.state, "paused")
pause_playback(); eq("Pause while paused stays paused (gated, no toggle)", PB.state, "paused")
play_resume();    eq("Play/Resume while paused -> playing", PB.state, "playing")
play_resume();    eq("Play/Resume while playing stays playing", PB.state, "playing")
seek_back();      eq("Back 5s from 30s -> 25s", PB.time_us, 25 * 1000000)
seek_fwd();       eq("Fwd 5s from 25s -> 30s", PB.time_us, 30 * 1000000)
PB.time_us = 2 * 1000000; seek_back(); eq("Back 5s from 2s clamps to 0", PB.time_us, 0)
PB.state = "stopped"; play_resume(); eq("Play/Resume from stopped -> playing", PB.state, "playing")

--------------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
