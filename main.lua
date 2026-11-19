--- @since 25.12.29
--- smart-create.yazi  v0.4.0  (2026-09-23)
--- Ersetzt `create`. Template-Wahl fuer NAME[.Q].EXT aus <config>/templates:
---   1. NAME.Q.EXT und Template-Stamm endet auf Q (Trenner _ . - Leerz.) -> NAME.EXT
---   2. sonst alphabetisch erstes Template mit .EXT -> Name unveraendert
---   3. sonst leere Datei, Name unveraendert
--- Versteckte Dateien und Unterordner in templates/ werden ignoriert.
--- Aenderungen ggue. v0.3.0:
---   1. `refresh` nach dem Anlegen im CWD: Listing wird sofort neu gelesen statt
---      auf den File-Watcher (~200 ms) zu warten
---   2. Dateien: reveal sofort + refresh; Ordner: refresh, Poll alle 5 ms,
---      dann reveal --no-dummy (Timeout 300 ms -> normales reveal)
---   3. NOTIFY standardmaessig aus (natives create meldet ebenfalls nichts)
---   4. Timing per ya.dbg (sichtbar nur mit YAZI_LOG=debug)
---   5. Namen ohne Endung: templates/ wird gar nicht gelesen

local HOME = os.getenv("HOME") or ""
local CFG = os.getenv("YAZI_CONFIG_HOME")
  or ((os.getenv("XDG_CONFIG_HOME") or (HOME .. "/.config")) .. "/yazi")
local TPL_DIR = CFG .. "/templates"
local POS = { "top-center", y = 3, w = 50 }
local SEP = { ["_"] = true, ["."] = true, ["-"] = true, [" "] = true }
local NOTIFY = false                   -- Meldung "Template: ..." nach dem Anlegen
local WAIT_STEP, WAIT_MAX = 0.005, 60  -- Ordner-Hover: max. 300 ms auf Listing warten

local get_cwd = ya.sync(function() return tostring(cx.active.current.cwd) end)

-- true: Eintrag im Listing, false: noch nicht, nil: CWD inzwischen gewechselt
local listed = ya.sync(function(_, dir, name)
  local cur = cx.active.current
  if tostring(cur.cwd) ~= dir then return nil end
  local files = cur.files
  for i = 1, #files do
    if files[i].url.name == name then return true end
  end
  return false
end)

local function notify(msg, level)
  ya.notify {
    title = "smart-create", content = msg, timeout = 3, level = level or "info",
  }
end

local function trace(t0, what)
  ya.dbg(string.format("smart-create: %s nach %.1f ms", what, (ya.time() - t0) * 1000))
end

local function templates()
  local files = fs.read_dir(Url(TPL_DIR), { resolve = true })
  local list = {}
  for _, f in ipairs(files or {}) do
    local name = f.url.name
    local stem, ext = name:match("^(.+)%.([^.]+)$")
    if stem and name:sub(1, 1) ~= "." and not f.cha.is_dir then
      list[#list + 1] = { name = name, stem = stem:lower(), ext = ext:lower() }
    end
  end
  table.sort(list, function(a, b)
    local la, lb = a.name:lower(), b.name:lower()
    if la ~= lb then return la < lb end
    return a.name < b.name
  end)
  return list
end

local function ends_with_q(stem, q)
  if stem == q then return true end
  local n = #stem - #q
  return n > 0 and stem:sub(n + 1) == q and SEP[stem:sub(n, n)] == true
end

-- Liefert (Zielname, Templatepfad|nil)
local function resolve(leaf)
  local e = leaf:match("^.+%.([^.]+)$")
  if not e then return leaf, nil end
  local list = templates()
  local base, q, ext = leaf:match("^(.+)%.([^.]+)%.([^.]+)$")
  if base then
    local lq, lext = q:lower(), ext:lower()
    for _, t in ipairs(list) do
      if t.ext == lext and ends_with_q(t.stem, lq) then
        return base .. "." .. ext, TPL_DIR .. "/" .. t.name
      end
    end
  end
  e = e:lower()
  for _, t in ipairs(list) do
    if t.ext == e then return leaf, TPL_DIR .. "/" .. t.name end
  end
  return leaf, nil
end

local function slurp(p)
  local fh, err = io.open(p, "rb")
  if not fh then return nil, err end
  local d = fh:read("*a")
  fh:close()
  return d
end

local function reveal(path, cwd, is_dir, t0)
  local dir, name = path:match("^(.*)/([^/]+)$")
  local here = dir == cwd and name:sub(1, 1) ~= "."
  if not (is_dir and here) then
    ya.emit("reveal", { path })
    if here then ya.emit("refresh", {}) end
    return trace(t0, "reveal")
  end
  ya.emit("refresh", {})
  for _ = 1, WAIT_MAX do
    local seen = listed(cwd, name)
    if seen == nil then return end
    if seen then
      ya.emit("reveal", { path, no_dummy = true })
      return trace(t0, "reveal --no-dummy")
    end
    ya.sleep(WAIT_STEP)
  end
  ya.emit("reveal", { path })
  trace(t0, "reveal (Timeout)")
end

local function entry()
  local value, event = ya.input { title = "Create:", pos = POS }
  if event ~= 1 or not value or value == "" then return end
  local t0 = ya.time()
  if value:sub(1, 2) == "~/" then value = HOME .. value:sub(2) end

  local cwd = get_cwd()
  local full = value
  if value:sub(1, 1) ~= "/" then
    if cwd:sub(1, 1) ~= "/" then
      return notify("Nur in lokalen Verzeichnissen: " .. cwd, "error")
    end
    full = cwd .. "/" .. value
  end

  -- Trailing "/" -> Verzeichnis (wie Original-create)
  if full:sub(-1) == "/" then
    local path = full:gsub("/+$", "")
    if path == "" then return end
    local ok, err = fs.create("dir_all", Url(path))
    if not ok then return notify(tostring(err), "error") end
    return reveal(path, cwd, true, t0)
  end

  local dir, leaf = full:match("^(.*)/([^/]+)$")
  local name, tpl = resolve(leaf)
  local target = dir .. "/" .. name

  local cha = fs.cha(Url(target))
  if cha then
    if cha.is_dir then return notify("Verzeichnis existiert: " .. target, "error") end
    local a, ev = ya.input { title = "Overwrite " .. name .. "? (y/N)", pos = POS }
    if ev ~= 1 or not (a or ""):match("^[yYjJ]") then return end
  end

  if dir ~= "" then
    local ok, err = fs.create("dir_all", Url(dir))
    if not ok then return notify(tostring(err), "error") end
  end

  local data = ""
  if tpl then
    local d, e = slurp(tpl)
    if not d then return notify(tostring(e), "error") end
    data = d
  end
  local ok, err = fs.write(Url(target), data)
  if not ok then return notify(tostring(err), "error") end
  if tpl and NOTIFY then notify("Template: " .. tpl:match("[^/]+$")) end
  reveal(target, cwd, false, t0)
end

return { entry = entry, _resolve = resolve }
