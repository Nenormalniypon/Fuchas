local GUI = require("GUI")
local system = require("System")
local image = require("Image")
local filesystem = require("Filesystem")
local internet = require("Internet")

local workspace, window, menu = system.addWindow(GUI.filledWindow(1, 1, 60, 23, 0xE1E1E1))
local localization = system.getCurrentScriptLocalization()

local branch = "main"

-- GitHub raw is the primary source; jsDelivr and raw.githack are mirrors in
-- case GitHub raw is blocked or rate-limited.
local function download(file, destination)
  local bases = {
    "https://raw.githubusercontent.com/Nenormalniypon/Fuchas/" .. branch .. "/",
    "https://cdn.jsdelivr.net/gh/Nenormalniypon/Fuchas@" .. branch .. "/",
    "https://raw.githack.com/Nenormalniypon/Fuchas/" .. branch .. "/"
  }
  local lastError
  for _, base in ipairs(bases) do
    local ok, err = internet.download(base .. file, destination)
    if ok ~= false then
      return true
    end
    lastError = err
  end
  return false, lastError
end

localization.tryit = localization.tryit or "Try It!"
localization.install = localization.install or "Install"
localization.installDev = localization.installDev or "Install (UNSAFE)"

local layout = window:addChild(GUI.layout(1, 1, window.width, window.height, 1, 1))
local layout2 = GUI.layout(1, 1, window.width, window.height, 1, 1)
local fuchasIcon = image.load(filesystem.path(system.getCurrentScript()) .. "/Logo.pic")
local icon = GUI.image(1, 1, fuchasIcon)
local tryButton = GUI.roundedButton(1, 1, 35, 5, 0xFFFFFF, 0x555555, 0x880000, 0xFFFFFF, localization.tryit)
local installButton = GUI.roundedButton(1, 1, 13, 3, 0xFFFFFF, 0x555555, 0x880000, 0xFFFFFF, localization.install)
local installButton2 = GUI.roundedButton(1, 1, 13, 3, 0xFFFFFF, 0x555555, 0x880000, 0xFFFFFF, localization.install)
local changelogBox = GUI.textBox(1, 1, 60, 15, 0xFFFFFF, 0x000000, {}, 1, 1, 1, true, false)
local installDevButton = GUI.roundedButton(1, 1, 15, 1, 0xFFFFFF, 0x555555, 0x880000, 0xFFFFFF, localization.installDev)
local progressText = GUI.text(1, 1, 0x555555, "Downloading..")

tryButton.onTouch = function()
  GUI.alert("Not supported yet! Please Install")
end

local function extract(stream, progressBar)
  local dent = {
    magic = 0,
    dev = 0,
    ino = 0,
    mode = 0,
    uid = 0,
    gid = 0,
    nlink = 0,
    rdev = 0,
    mtime = 0,
    namesize = 0,
    filesize = 0
  }
  local sawInit = false

  -- MineOS has shipped a few different file handle APIs over time.  Pick
  -- whichever reader is actually available instead of assuming one of them.
  local readSome
  if type(stream.readString) == "function" then
    readSome = function(n) return stream:readString(n) end
  elseif type(stream.read) == "function" then
    readSome = function(n) return stream:read(n) end
  elseif type(stream.readBytes) == "function" then
    readSome = function(n) return stream:readBytes(n) end
  else
    error("file stream does not provide a read method")
  end

  local function readExact(n)
    if n == 0 then return "" end
    local chunks, got = {}, 0
    while got < n do
      local part = readSome(n - got)
      if not part or #part == 0 then
        error("unexpected end of cpio archive")
      end
      chunks[#chunks + 1] = part
      got = got + #part
    end
    return table.concat(chunks)
  end

  -- Little-endian integer, computed without bit32 so this also works on
  -- Lua 5.3/5.4 installations where bit32 does not exist.
  local function readint(amt)
    local data = readExact(amt)
    local value = 0
    for i = amt, 1, -1 do
      value = value * 256 + data:byte(i)
    end
    return value
  end

  local function ensureDirectory(path)
    local current = ""
    for part in path:gmatch("[^/]+") do
      current = current .. "/" .. part
      pcall(filesystem.makeDirectory, current)
    end
  end

  local function fwrite()
    local dir = dent.name:match("^(.*)/[^/]+$")
    if dir then
      ensureDirectory("/" .. dir)
    end
    local hand, err = filesystem.open("/" .. dent.name, "w")
    if not hand then
      error("cannot write " .. dent.name .. ": " .. tostring(err))
    end
    hand:write(readExact(dent.filesize))
    hand:close()
  end

  while true do
    dent.magic = readint(2)
    -- Old binary cpio uses 070707.  A byte-swapped archive is possible, but
    -- the format is little-endian in practice; report it instead of silently
    -- mis-parsing the remaining fields.
    if dent.magic ~= tonumber("070707", 8) then
      error("invalid cpio magic: " .. tostring(dent.magic))
    end
    dent.dev = readint(2)
    dent.ino = readint(2)
    dent.mode = readint(2)
    dent.uid = readint(2)
    dent.gid = readint(2)
    dent.nlink = readint(2)
    dent.rdev = readint(2)
    dent.mtime = readint(2) * 65536 + readint(2)
    dent.namesize = readint(2)
    dent.filesize = readint(2) * 65536 + readint(2)
    local name = readExact(dent.namesize):sub(1, dent.namesize - 1)
    if name == "TRAILER!!!" then break end
    dent.name = name
    if name == "init.lua" then sawInit = true end
    progressText.text = "Extracting " .. dent.name
    if progressBar.roll then
      progressBar:roll()
    end
    workspace:draw()
    if require("Screen").update then
      require("Screen").update()
    end
    if dent.namesize % 2 ~= 0 then
      readExact(1) -- consume name padding (no seek required)
    end
    -- Mode 0100000 marks a regular file, 040000 a directory.  Use arithmetic
    -- to stay bit32-free.
    if math.floor(dent.mode / 32768) % 2 == 1 then
      fwrite()
    elseif math.floor(dent.mode / 16384) % 2 == 1 then
      ensureDirectory("/" .. dent.name)
    elseif dent.filesize > 0 then
      -- Keep the stream in sync even for entry types we do not extract.
      readExact(dent.filesize)
    end
    if dent.filesize % 2 ~= 0 then
      readExact(1) -- consume data padding
    end
  end
  return sawInit
end

local function readChangelog()
  local url = "https://raw.githubusercontent.com/Nenormalniypon/Fuchas/" .. branch .. "/release.lon"
  local ok, text = pcall(function()
    return require("Text").deserialize(internet.request(url))
  end)
  if not ok or type(text) ~= "table" or not text.changelog then
    changelogBox.lines = {"Could not download the changelog.", "Check the internet connection and try again."}
    return
  end
  local lines = {}
  table.insert(lines, "Fuchas Version " .. tostring(text.version))
  table.insert(lines, " ")
  for w in string.gmatch(text.changelog, "([^\n]+)") do
    table.insert(lines, w)
  end
  changelogBox.lines = lines
end

local function install(progressBar)
  local ok, err = download("release.cpio", "/Temporary/fuchas.cpio")
  if ok == false then
    error("download failed: " .. tostring(err))
  end
  local stream, openErr = filesystem.open("/Temporary/fuchas.cpio", "rb")
  if not stream then
    error(openErr or "cannot open downloaded archive")
  end
  local bundledInit = extract(stream, progressBar)
  stream:close()
  -- release.cpio bundles init.lua since 0.7.1.  Only download it for older
  -- archives that do not contain a boot loader.
  if not bundledInit then
    ok, err = download("init.lua", "/init.lua")
    if ok == false then
      error("download failed: " .. tostring(err))
    end
  end
end

installButton2.onTouch = function()
  installButton2:remove()
  changelogBox:remove()
  local progressBar = GUI.progressIndicator(1, 1, 0x3C3C3C, 0x00B640, 0x99FF80)
  progressBar.active = true
  layout:addChild(progressBar)
  layout:addChild(progressText)
  local ok, err = pcall(install, progressBar)
  if not ok then
    GUI.alert("Installation failed: " .. tostring(err))
    progressBar:remove()
    progressText:remove()
    layout:remove()
    window:addChild(layout2)
    return
  end
  pcall(filesystem.rename, "/OS.lua", "/_OS.lua")
  progressBar:remove()
  progressText.text = "'cp _OS.lua A:/OS.lua' to get back to MineOS."
end

installButton.onTouch = function()
  readChangelog()
  installButton:remove()
  tryButton:remove()
  layout:remove()
  window:addChild(layout2)
end

installDevButton.onTouch = function()
  branch = "dev"
  installButton.onTouch()
end

layout:addChild(icon)
layout:addChild(tryButton)
layout:addChild(installButton)
layout:addChild(installDevButton)

layout2:addChild(changelogBox)
layout2:addChild(installButton2)

window.onResize = function(newWidth, newHeight)
  window.backgroundPanel.width, window.backgroundPanel.height = newWidth, newHeight
  layout.width, layout.height = newWidth, newHeight
  layout2.width, layout2.height = newWidth, newHeight
  changelogBox.width, changelogBox.height = newWidth, newHeight-8
end

---------------------------------------------------------------------------------

-- Draw changes on screen after customizing your window
workspace:draw()
