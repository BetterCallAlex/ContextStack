--- === ContextStack ===
---
--- Quick "recent windows → context for AI chats" picker for macOS.
---
--- Keeps a small history of recently focused windows. On a hotkey it shows a
--- Spotlight-style picker of the last few windows; picking one offers capture
--- actions (page text, URL, full HTML, screenshot, document path/contents,
--- window text). The result lands on the clipboard (and in ~/ContextStack/)
--- ready to paste into the Claude app or Claude Code.
---
--- Nothing is captured until you pick — the history holds only window
--- references, titles and timestamps.

local obj = {}
obj.__index = obj

obj.name = "ContextStack"
obj.version = "0.1.0"
obj.author = "alex"
obj.license = "MIT"

-- ------------------------------------------------------------------ config

--- Number of recent windows shown in the picker.
obj.maxEntries = 7

--- Where captures (markdown/PNG) are written.
obj.captureDir = os.getenv("HOME") .. "/ContextStack"

--- Show a notification after each capture.
obj.notifyOnCopy = true

--- Automatically press Cmd+V into the frontmost app after a capture lands
--- on the clipboard. On by default — picking an action pastes directly;
--- set to false if you'd rather paste yourself.
obj.autoPaste = true

--- Truncate "file contents" captures beyond this many bytes.
obj.maxFileBytes = 256 * 1024

--- Browsers that speak the Chrome AppleScript dictionary (bundle ID → name
--- to use in `tell application`).
obj.chromiumBundles = {
  ["com.google.Chrome"] = "Google Chrome",
  ["com.google.Chrome.canary"] = "Google Chrome Canary",
  ["com.brave.Browser"] = "Brave Browser",
  ["com.microsoft.edgemac"] = "Microsoft Edge",
  ["company.thebrowser.Browser"] = "Arc",
  ["com.vivaldi.Vivaldi"] = "Vivaldi",
}

--- Browsers that speak the Safari AppleScript dictionary.
obj.safariBundles = {
  ["com.apple.Safari"] = "Safari",
  ["com.apple.SafariTechnologyPreview"] = "Safari Technology Preview",
}

--- Apps never recorded in the history.
obj.excludeBundles = {
  ["org.hammerspoon.Hammerspoon"] = true,
}

-- ------------------------------------------------------------------ state

local history = {} -- newest first: {id, win, app, bundleID, title, time}

local TEXT_EXT = {
  txt = true, md = true, markdown = true, rst = true, py = true, js = true,
  ts = true, tsx = true, jsx = true, json = true, yaml = true, yml = true,
  toml = true, ini = true, cfg = true, conf = true, sh = true, bash = true,
  zsh = true, lua = true, c = true, h = true, cpp = true, hpp = true,
  rs = true, go = true, java = true, swift = true, kt = true, rb = true,
  php = true, html = true, htm = true, css = true, scss = true, xml = true,
  csv = true, tsv = true, log = true, sql = true, tex = true, bib = true,
}

-- ------------------------------------------------------------------ helpers

local function log(...) print("[ContextStack]", ...) end

local function notify(title, text)
  if obj.notifyOnCopy then
    hs.notify.new({ title = title, informativeText = text or "" }):send()
  end
  log(title, text)
end

local function ensureDir()
  hs.fs.mkdir(obj.captureDir)
end

local function sanitize(s)
  s = tostring(s or ""):gsub("[^%w%-_ ]", ""):gsub("%s+", "-")
  if s == "" then s = "untitled" end
  return s:sub(1, 48)
end

local function captureName(entry, ext)
  return string.format("%s-%s.%s", os.date("%Y%m%d-%H%M%S"),
    sanitize(entry.app .. "-" .. (entry.title or "")), ext)
end

local function saveCapture(basename, content)
  ensureDir()
  local path = obj.captureDir .. "/" .. basename
  local f = io.open(path, "w")
  if not f then return nil end
  f:write(content)
  f:close()
  return path
end

local function ago(t)
  local d = os.time() - t
  if d < 60 then return d .. "s ago" end
  if d < 3600 then return math.floor(d / 60) .. "m ago" end
  return math.floor(d / 3600) .. "h ago"
end

local function setClipboard(text)
  hs.pasteboard.setContents(text)
end

local function maybeAutoPaste()
  if obj.autoPaste then
    hs.timer.doAfter(0.2, function()
      hs.eventtap.keyStroke({ "cmd" }, "v")
    end)
  end
end

-- Deliver a text capture: clipboard + file + notification.
local function deliverText(entry, kind, source, content)
  local header = string.format("# Context: %s — %s\nSource: %s\nCaptured: %s\n\n",
    entry.app, entry.title or "", source or "n/a", os.date("%Y-%m-%d %H:%M:%S"))
  local full = header .. content
  local path = saveCapture(captureName(entry, "md"), full)
  setClipboard(full)
  notify("ContextStack: " .. kind .. " copied",
    string.format("%s — %s (%d chars)\nSaved: %s",
      entry.app, entry.title or "", #content, path or "not saved"))
  maybeAutoPaste()
end

-- ------------------------------------------------------------------ AppleScript

local function escAS(s)
  return (tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"'))
end

local function osa(script)
  local ok, result = hs.osascript.applescript(script)
  if ok then return result end
  log("AppleScript failed:", hs.inspect(result))
  return nil
end

local function browserFamily(entry)
  if obj.chromiumBundles[entry.bundleID] then
    return "chromium", obj.chromiumBundles[entry.bundleID]
  end
  if obj.safariBundles[entry.bundleID] then
    return "safari", obj.safariBundles[entry.bundleID]
  end
  return nil
end

-- Find the tab matching the remembered window title (the tab may have moved
-- or another tab may be active now); fall back to the active tab.
-- Returns url, title or nil.
local function resolveTab(family, appName, wantedTitle)
  local script
  if family == "chromium" then
    script = string.format([[
tell application "%s"
	set wanted to "%s"
	set theURL to ""
	set theTitle to ""
	repeat with w in windows
		repeat with t in tabs of w
			if (title of t as text) is wanted then
				set theURL to URL of t
				set theTitle to title of t
			end if
		end repeat
	end repeat
	if theURL is "" then
		set theURL to URL of active tab of front window
		set theTitle to title of active tab of front window
	end if
	return {theURL, theTitle}
end tell]], appName, escAS(wantedTitle))
  else
    script = string.format([[
tell application "%s"
	set wanted to "%s"
	set theURL to ""
	set theTitle to ""
	repeat with w in windows
		repeat with t in tabs of w
			if (name of t as text) is wanted then
				set theURL to URL of t
				set theTitle to name of t
			end if
		end repeat
	end repeat
	if theURL is "" then
		set theURL to URL of current tab of front window
		set theTitle to name of current tab of front window
	end if
	return {theURL, theTitle}
end tell]], appName, escAS(wantedTitle))
  end
  local r = osa(script)
  if type(r) == "table" and type(r[1]) == "string" and r[1] ~= "" then
    return r[1], r[2]
  end
  return nil
end

-- Run JavaScript in the remembered tab (needs "Allow JavaScript from Apple
-- Events" enabled in the browser). Returns the JS result string or nil.
local function runTabJS(family, appName, wantedTitle, js)
  local script
  if family == "chromium" then
    script = string.format([[
tell application "%s"
	set wanted to "%s"
	set theTab to missing value
	repeat with w in windows
		repeat with t in tabs of w
			if (title of t as text) is wanted then set theTab to t
		end repeat
	end repeat
	if theTab is missing value then set theTab to active tab of front window
	return execute theTab javascript "%s"
end tell]], appName, escAS(wantedTitle), escAS(js))
  else
    script = string.format([[
tell application "%s"
	set wanted to "%s"
	set theTab to missing value
	repeat with w in windows
		repeat with t in tabs of w
			if (name of t as text) is wanted then set theTab to t
		end repeat
	end repeat
	if theTab is missing value then set theTab to current tab of front window
	return do JavaScript "%s" in theTab
end tell]], appName, escAS(wantedTitle), escAS(js))
  end
  local r = osa(script)
  if type(r) == "string" and #r > 0 then return r end
  return nil
end

-- ------------------------------------------------------------------ capture: browser

-- Convert an HTML string to plain text using macOS textutil.
local function htmlToText(html, cb)
  local tmp = os.tmpname() .. ".html"
  local f = io.open(tmp, "w")
  if not f then cb(nil) return end
  f:write(html)
  f:close()
  local task = hs.task.new("/usr/bin/textutil", function(exitCode, stdOut, _)
    os.remove(tmp)
    if exitCode == 0 and stdOut and #stdOut > 0 then cb(stdOut) else cb(nil) end
  end, { "-convert", "txt", "-stdout", tmp })
  task:start()
end

local function capturePage(entry, wantHTML)
  local family, appName = browserFamily(entry)
  if not family then return end
  local url = resolveTab(family, appName, entry.title)

  -- Preferred: run JS in the live tab — sees the rendered page, including
  -- logged-in content and SPAs.
  local js = wantHTML and "document.documentElement.outerHTML"
    or "document.body.innerText"
  local res = runTabJS(family, appName, entry.title, js)
  if res then
    deliverText(entry, wantHTML and "full HTML" or "page text", url, res)
    return
  end

  -- Fallback: plain fetch of the URL (no login/session, but always works).
  if not url then
    notify("ContextStack", "Could not get a URL from " .. appName ..
      " (check Automation permission for Hammerspoon)")
    return
  end
  hs.http.asyncGet(url, nil, function(status, body, _)
    if status ~= 200 or not body then
      notify("ContextStack", string.format("Fetch failed (%s) for %s", tostring(status), url))
      return
    end
    if wantHTML then
      deliverText(entry, "full HTML (fetched)", url, body)
    else
      htmlToText(body, function(txt)
        if txt then
          deliverText(entry, "page text (fetched)", url, txt)
        else
          deliverText(entry, "raw HTML (fetched)", url, body)
        end
      end)
    end
  end)
end

local function captureLink(entry)
  local family, appName = browserFamily(entry)
  if not family then return end
  local url, title = resolveTab(family, appName, entry.title)
  if not url then
    notify("ContextStack", "Could not get a URL from " .. appName)
    return
  end
  setClipboard(string.format("[%s](%s)", title or entry.title or url, url))
  notify("ContextStack: link copied", url)
  maybeAutoPaste()
end

-- ------------------------------------------------------------------ capture: screenshot

local function captureScreenshot(entry, pathOnly)
  local ok, img = pcall(function() return entry.win and entry.win:snapshot() end)
  if not ok or not img then
    notify("ContextStack", "Snapshot failed — window gone, or Hammerspoon lacks Screen Recording permission")
    return
  end
  ensureDir()
  local path = obj.captureDir .. "/" .. captureName(entry, "png")
  img:saveToFile(path)
  if pathOnly then
    setClipboard(path)
    notify("ContextStack: screenshot path copied", path)
  else
    hs.pasteboard.writeObjects(img)
    notify("ContextStack: screenshot copied as image", "Also saved: " .. path)
  end
  maybeAutoPaste()
end

-- ------------------------------------------------------------------ capture: documents & window text

local function documentPath(entry)
  if not entry.win then return nil end
  local ok, path = pcall(function()
    local el = hs.axuielement.windowElement(entry.win)
    if not el then return nil end
    local doc = el:attributeValue("AXDocument")
    if type(doc) ~= "string" or doc == "" then return nil end
    doc = doc:gsub("^file://", "")
    doc = doc:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return doc
  end)
  if ok then return path end
  return nil
end

local function readTextFile(path)
  local ext = path:match("%.(%w+)$")
  if not ext or not TEXT_EXT[ext:lower()] then
    return nil, "not a text file (by extension)"
  end
  local f = io.open(path, "rb")
  if not f then return nil, "cannot open file" end
  local data = f:read(obj.maxFileBytes + 1) or ""
  f:close()
  if data:find("\0", 1, true) then return nil, "binary file" end
  if #data > obj.maxFileBytes then
    data = data:sub(1, obj.maxFileBytes) .. "\n\n[... truncated by ContextStack ...]"
  end
  return data
end

local function collectAXText(el, acc, depth, budget)
  if not el or depth > 12 or budget.n <= 0 then return end
  budget.n = budget.n - 1
  local role = el:attributeValue("AXRole")
  if role == "AXStaticText" or role == "AXTextArea" or role == "AXTextField" then
    local v = el:attributeValue("AXValue")
    if type(v) == "string" and #v > 0 then acc[#acc + 1] = v end
  end
  local kids = el:attributeValue("AXChildren")
  if type(kids) == "table" then
    for _, k in ipairs(kids) do
      collectAXText(k, acc, depth + 1, budget)
    end
  end
end

local function captureWindowText(entry)
  if not entry.win then
    notify("ContextStack", "Window is gone")
    return
  end
  local ok, text = pcall(function()
    local el = hs.axuielement.windowElement(entry.win)
    if not el then return nil end
    local acc = {}
    collectAXText(el, acc, 0, { n = 3000 })
    return table.concat(acc, "\n")
  end)
  if ok and text and #text > 0 then
    deliverText(entry, "window text (Accessibility)", entry.app, text)
  else
    notify("ContextStack",
      "No text found via Accessibility — try the screenshot action instead")
  end
end

-- ------------------------------------------------------------------ actions

local function actionsFor(entry)
  local acts = {}
  local function add(text, subText, fn)
    acts[#acts + 1] = { text = text, subText = subText, fn = fn }
  end

  local family = browserFamily(entry)
  local doc = documentPath(entry)

  if family then
    add("Page text", "Readable text of the tab (JS in tab; falls back to fetching the URL)",
      function() capturePage(entry, false) end)
    add("Link (markdown)", "Copy [title](url) of the tab",
      function() captureLink(entry) end)
    add("Full HTML", "Complete HTML of the tab",
      function() capturePage(entry, true) end)
  end

  if doc then
    local short = doc:gsub("^" .. os.getenv("HOME"), "~")
    add("File path — " .. short, "Copy the document's path",
      function()
        setClipboard(doc)
        notify("ContextStack: path copied", doc)
        maybeAutoPaste()
      end)
    add("@-reference (Claude Code)", "Copy '@" .. short .. "'",
      function()
        setClipboard("@" .. doc)
        notify("ContextStack: @-reference copied", "@" .. doc)
        maybeAutoPaste()
      end)
    add("File contents", "Copy the document text itself (text formats only)",
      function()
        local data, err = readTextFile(doc)
        if data then
          deliverText(entry, "file contents", doc, data)
        else
          notify("ContextStack", "Cannot copy contents: " .. (err or "?") ..
            " — copied the path instead")
          setClipboard(doc)
        end
      end)
  end

  add("Screenshot → clipboard", "Window snapshot as image + saved PNG (needs Screen Recording)",
    function() captureScreenshot(entry, false) end)
  add("Screenshot → file path", "Snapshot saved as PNG, its path copied (for Claude Code)",
    function() captureScreenshot(entry, true) end)

  if not family then
    add("Window text (best effort)", "Extract visible text via Accessibility",
      function() captureWindowText(entry) end)
  end

  add("Title line", "Copy 'App — window title' as plain text",
    function()
      setClipboard(string.format("%s — %s", entry.app, entry.title or ""))
      notify("ContextStack: title copied", entry.title or "")
      maybeAutoPaste()
    end)

  return acts
end

local function showActions(entry)
  local acts = actionsFor(entry)
  obj._actionChooser = hs.chooser.new(function(choice)
    if not choice then return end
    local a = acts[choice.idx]
    if a then a.fn() end
  end)
  local choices = {}
  for i, a in ipairs(acts) do
    choices[i] = { text = a.text, subText = a.subText, idx = i }
  end
  obj._actionChooser:choices(choices)
  obj._actionChooser:rows(math.min(#choices, 9))
  obj._actionChooser:placeholderText(string.format("%s — %s", entry.app, entry.title or ""))
  obj._actionChooser:show()
end

-- ------------------------------------------------------------------ history tracking

local function onFocus(win, appName)
  if not win then return end
  local app = win:application()
  local bundleID = (app and app:bundleID()) or ""
  if obj.excludeBundles[bundleID] then return end
  local okId, id = pcall(function() return win:id() end)
  if not okId or not id then return end
  local entry = {
    id = id,
    win = win,
    app = appName or (app and app:name()) or "?",
    bundleID = bundleID,
    title = win:title() or "",
    time = os.time(),
  }
  for i, e in ipairs(history) do
    if e.id == id then
      table.remove(history, i)
      break
    end
  end
  table.insert(history, 1, entry)
  while #history > obj.maxEntries + 3 do
    table.remove(history)
  end
end

-- ------------------------------------------------------------------ picker

local function kindLabel(entry)
  if browserFamily(entry) then return "browser tab" end
  if documentPath(entry) then return "document" end
  return "window"
end

--- ContextStack:show()
--- Method
--- Show the recent-windows picker.
function obj:show()
  local focused = hs.window.focusedWindow()
  local fid = focused and focused:id()
  local choices = {}
  for _, e in ipairs(history) do
    if e.id ~= fid then
      choices[#choices + 1] = {
        text = string.format("%s — %s", e.app,
          e.title ~= "" and e.title or "(untitled)"),
        subText = string.format("%s · %s", kindLabel(e), ago(e.time)),
        uuid = tostring(e.id),
        image = e.bundleID ~= "" and hs.image.imageFromAppBundle(e.bundleID) or nil,
      }
      if #choices >= obj.maxEntries then break end
    end
  end
  if #choices == 0 then
    notify("ContextStack", "No recent windows yet — switch between some apps first")
    return
  end
  self.chooser:choices(choices)
  self.chooser:rows(math.min(#choices, 9))
  self.chooser:show()
end

-- ------------------------------------------------------------------ lifecycle

function obj:init()
  self.chooser = hs.chooser.new(function(choice)
    if not choice then return end
    local entry
    for _, e in ipairs(history) do
      if tostring(e.id) == choice.uuid then
        entry = e
        break
      end
    end
    if not entry then return end
    hs.timer.doAfter(0.05, function() showActions(entry) end)
  end)
  self.chooser:searchSubText(true)
  return self
end

--- ContextStack:start()
--- Method
--- Begin tracking focused windows.
function obj:start()
  ensureDir()
  self.wf = hs.window.filter.default
  self.wf:subscribe(hs.window.filter.windowFocused, onFocus)
  local cur = hs.window.focusedWindow()
  if cur then
    onFocus(cur, cur:application() and cur:application():name())
  end
  log("started, capture dir: " .. obj.captureDir)
  return self
end

--- ContextStack:stop()
--- Method
--- Stop tracking focused windows.
function obj:stop()
  if self.wf then
    self.wf:unsubscribe(onFocus)
  end
  return self
end

--- ContextStack:bindHotkeys(mapping)
--- Method
--- Bind hotkeys. Supported key: `show`.
---
--- Example: `spoon.ContextStack:bindHotkeys({ show = {{"ctrl","alt"}, "space"} })`
function obj:bindHotkeys(mapping)
  local spec = { show = hs.fnutils.partial(self.show, self) }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  return self
end

return obj
