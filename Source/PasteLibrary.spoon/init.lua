-- Copyright (c) 2025 Christopher Maahs
-- MIT License

--- === PasteLibrary ===
---
--- Canvas-based paste library with paging and delete mode:
---  - 3x5 grid (columns A..C, rows A..E)
---  - Column key (A..C) then Row key (A..E) to select a cell
---  - A,A = Add new item dialog (disabled in delete mode)
---  - Column letters turn blue when column selected; other columns fade
---  - Paging for unlimited items (14 per page, A,A reserved)
---  - J / → next page, K / ← previous page (wrap-around)
---  - Footer panel below grid shows "Page X / Y" (or delete mode text)
---  - Delete Mode (X to toggle): red overlay + red footer; selecting deletes
---  - Soft pulse flash on deleted cell
---  - Snappy fade-in/out (0.10s), page crossfade (0.08s)
---
--- Storage: ${HOME}/.config/pastelibrary/items.json

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "PasteLibrary"
obj.version = "2.3.4"
obj.author = "Christopher Maahs"
obj.homepage = "https://github.com/maahsome/PasteLibrary.spoon"
obj.license = "MIT"

-- Storage / Items
obj.storageDir  = os.getenv("HOME") .. "/.config/pastelibrary"
obj.storageFile = obj.storageDir .. "/items.json"
obj.items       = {} -- { {title="...", body="..."}, ... }

-- UI state
obj.bgCanvas        = nil -- fullscreen dim layer
obj.gridCanvas      = nil -- centered grid
obj.footerCanvas    = nil -- footer panel under the grid
obj._keysTap        = nil
obj._selectedCol    = nil         -- 1..3 or nil
obj._cellItemIndex  = {}          -- [r][c] -> items[] index (nil if none) for current page
obj._cells          = {}          -- [r][c] -> { rectId=..., titleId=..., colLblId=..., rowLblId=..., frame={...} }
obj._lastFrontApp   = nil
obj._lastFrontWin   = nil

-- Delete Mode
obj._deleteMode      = false
obj._deleteOverlayId = "deleteOverlay"

-- Paging
obj.itemsPerPage    = 14
obj._currentPage    = 1
obj._totalPages     = 1

-- Layout / Style
obj.fadeAlpha       = 0.28
obj.gridCols        = 3
obj.gridRows        = 5
obj.gridMargin      = 16
obj.cellPadding     = 10
obj.cornerRadius    = 12
obj.titleFontSize   = 16
obj.hintFontSize    = 14
obj.dimAlpha        = 0.25        -- background dim overlay alpha
obj.gridWidthFrac   = 2/3         -- width of screen for grid canvas
obj.gridHeightFrac  = 0.60        -- height of screen for grid canvas
obj.animDuration    = 0.10        -- open/close fade
obj.pageAnim        = 0.08        -- page crossfade
obj.footerHeight    = 40
obj.footerGap       = 8           -- gap between grid panel and footer panel

-- Colors
local COLOR = {
  bgDim     = { black = 0, alpha = 0.25 },
  panelBG   = { white = 0.04, alpha = 0.95 },
  footerBG  = { white = 0.08, alpha = 0.95 }, -- slightly brighter than grid panel
  cellBG    = { white = 0.06, alpha = 0.96 },
  cellHi    = { white = 0.10, alpha = 0.98 },
  border    = { white = 1, alpha = 0.08 },
  title     = { white = 0.95, alpha = 0.95 },
  footerTx  = { white = 0.90, alpha = 0.90 },
  identY    = { red = 1.0,  green = 1.0,  blue = 0.0,  alpha = 1.0 },  -- yellow
  identB    = { red = 0.15, green = 0.45, blue = 1.0,  alpha = 1.0 },  -- blue

  -- Delete Mode visuals
  delOverlay = { red = 0.60, green = 0.00, blue = 0.00, alpha = 0.25 }, -- soft red tint over grid
  delFlash   = { red = 0.90, green = 0.20, blue = 0.20, alpha = 0.40 }, -- soft red flash on cell
  footerBGDel= { white = 0.06, alpha = 0.97 },                           -- darker footer bg
  footerTxDel= { red = 1.00, green = 0.35, blue = 0.35, alpha = 0.98 },  -- red footer text
}

-- Deps
local fs        = require("hs.fs")
local json      = require("hs.json")
local timer     = require("hs.timer")
local appmod    = require("hs.application")
local window    = require("hs.window")
local alert     = require("hs.alert").show
local eventtap  = require("hs.eventtap")
local pasteboard= require("hs.pasteboard")
local dialog    = require("hs.dialog")
local screen    = require("hs.screen")
local canvas    = require("hs.canvas")

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

local function ensureDirectory(path)
  local attrs = fs.attributes(path)
  if not attrs then
    os.execute(string.format('mkdir -p %q', path))
  elseif attrs.mode ~= "directory" then
    error("PasteLibrary: storage path exists and is not a directory: " .. path)
  end
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function writeFile(path, data)
  local f, err = io.open(path, "w")
  if not f then return nil, err end
  f:write(data)
  f:close()
  return true
end

local function normalizeItems(tbl)
  local out = {}
  if type(tbl) ~= "table" then return out end
  for _, v in ipairs(tbl) do
    if type(v) == "table" and type(v.title) == "string" and type(v.body) == "string" then
      table.insert(out, { title = v.title, body = v.body })
    end
  end
  return out
end

--------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------

function obj:loadItems()
  ensureDirectory(self.storageDir)
  local data = readFile(self.storageFile)
  if not data or data == "" then
    self.items = {}
    return
  end
  local ok, decoded = pcall(json.decode, data)
  if not ok then
    alert("PasteLibrary: Could not decode items.json; starting empty.")
    self.items = {}
    return
  end
  self.items = normalizeItems(decoded)
end

function obj:saveItems()
  ensureDirectory(self.storageDir)
  local encoded = json.encode(self.items, true)
  local ok, err = writeFile(self.storageFile, encoded)
  if not ok then
    alert("PasteLibrary: Failed to save items.json: " .. tostring(err))
  end
end

function obj:addItem(title, body)
  table.insert(self.items, { title = title, body = body })
  self:saveItems()
  self:_computePaging()
end

function obj:deleteItemByIndex(idx)
  if not idx or idx < 1 or idx > #self.items then return end
  table.remove(self.items, idx)
  self:saveItems()
  self:_computePaging()
end

function obj:deleteItemByTitle(title)
  local kept = {}
  for _, it in ipairs(self.items) do
    if it.title ~= title then table.insert(kept, it) end
  end
  self.items = kept
  self:saveItems()
  self:_computePaging()
end

--------------------------------------------------------------------------------
-- Focus & paste helpers
--------------------------------------------------------------------------------

function obj:_captureFront()
  self._lastFrontApp = appmod.frontmostApplication()
  self._lastFrontWin = window.frontmostWindow()
end

function obj:_restoreFront()
  if self._lastFrontApp and self._lastFrontApp:bundleID() then
    self._lastFrontApp:activate(true)
  end
  if self._lastFrontWin and self._lastFrontWin:id() then
    self._lastFrontWin:focus()
  end
end

function obj:_performPaste(body)
  if not body then return end
  pasteboard.setContents(body)
  timer.doAfter(0.08, function()
    eventtap.keyStroke({ "cmd" }, "v")
  end)
end

--------------------------------------------------------------------------------
-- Grid mapping & population
--------------------------------------------------------------------------------

local COLS = { "A", "B", "C" }
local ROWS = { "A", "B", "C", "D", "E" }

-- traversal order for the 14 item slots on a page (excluding A,A)
local function traversalOrder()
  local order = {}
  -- row 1: B,A then C,A
  table.insert(order, { r = 1, c = 2 })
  table.insert(order, { r = 1, c = 3 })
  -- then rows 2..5, cols 1..3
  for r = 2, 5 do
    for c = 1, 3 do
      table.insert(order, { r = r, c = c })
    end
  end
  return order
end

function obj:_computePaging()
  local count = #self.items
  self._totalPages = math.max(1, math.ceil(count / self.itemsPerPage))
  if self._currentPage > self._totalPages then
    self._currentPage = self._totalPages
  end
end

-- Build cell->item mapping for the current page
function obj:_assignItemsToCellsForPage(page)
  self._cellItemIndex = {}
  for r = 1, self.gridRows do
    self._cellItemIndex[r] = {}
    for c = 1, self.gridCols do
      self._cellItemIndex[r][c] = nil
    end
  end

  local startIdx = (page - 1) * self.itemsPerPage + 1
  local order = traversalOrder()
  for i, pos in ipairs(order) do
    local itemIdx = startIdx + (i - 1)
    if self.items[itemIdx] then
      self._cellItemIndex[pos.r][pos.c] = itemIdx
    end
  end
end

--------------------------------------------------------------------------------
-- Layout helpers
--------------------------------------------------------------------------------

local function makeId(r, c, kind)
  return string.format("%s_%d_%d", kind, r, c)
end

function obj:_gridFrames()
  local sf = screen.mainScreen():frame()
  local canvasW = math.floor(sf.w * self.gridWidthFrac)
  local canvasH = math.floor(sf.h * self.gridHeightFrac)
  local canvasX = math.floor(sf.x + (sf.w - canvasW) / 2)
  local canvasY = math.floor(sf.y + (sf.h - canvasH) / 2)

  local innerW = canvasW - (self.gridMargin * 2)
  local innerH = canvasH - (self.gridMargin * 2)
  local cellW = math.floor(innerW / self.gridCols)
  local cellH = math.floor(innerH / self.gridRows)

  -- footer directly below grid
  local footerFrame = {
    x = canvasX,
    y = canvasY + canvasH + obj.footerGap,
    w = canvasW,
    h = obj.footerHeight,
  }

  return {
    screenFrame = sf,
    gridFrame   = { x = canvasX, y = canvasY, w = canvasW, h = canvasH },
    innerOrigin = { x = self.gridMargin, y = self.gridMargin }, -- relative to gridCanvas
    cellSize    = { w = cellW, h = cellH },
    footerFrame = footerFrame,
  }
end

--------------------------------------------------------------------------------
-- Build canvases
--------------------------------------------------------------------------------

function obj:_buildCanvases()
  -- Clean any existing canvases
  if self.bgCanvas     then self.bgCanvas:delete();     self.bgCanvas     = nil end
  if self.gridCanvas   then self.gridCanvas:delete();   self.gridCanvas   = nil end
  if self.footerCanvas then self.footerCanvas:delete(); self.footerCanvas = nil end

  self:_computePaging()
  self:_assignItemsToCellsForPage(self._currentPage)

  local frames = self:_gridFrames()
  local sf  = frames.screenFrame
  local gf  = frames.gridFrame
  local org = frames.innerOrigin   -- relative to gridCanvas
  local cel = frames.cellSize
  local ff  = frames.footerFrame

  -- Background dim (fullscreen)
  self.bgCanvas = canvas.new(sf):level("overlay")
  self.bgCanvas[1] = {
    id = "bgDim",
    type = "rectangle",
    action = "fill",
    fillColor = COLOR.bgDim,
  }

  -- Grid canvas (centered panel)
  self.gridCanvas = canvas.new(gf):level("overlay")
  self.gridCanvas[1] = {
    id = "panelBG",
    type = "rectangle",
    action = "fill",
    fillColor = COLOR.panelBG,
    strokeColor = COLOR.border,
    strokeWidth = 1,
    roundedRectRadii = { xRadius = 14, yRadius = 14 },
    frame = { x = 0, y = 0, w = gf.w, h = gf.h }, -- relative to gridCanvas
  }

  -- Build cells
  self._cells = {}
  local idx = 2 -- start after panel background
  for r = 1, self.gridRows do
    self._cells[r] = {}
    for c = 1, self.gridCols do
      local x = org.x + (c - 1) * cel.w
      local y = org.y + (r - 1) * cel.h
      local cellRect = { x = x + 1, y = y + 1, w = cel.w - 2, h = cel.h - 2 }

      local rectId  = makeId(r, c, "rect")
      local titleId = makeId(r, c, "title")
      local colId   = makeId(r, c, "colLbl")
      local rowId   = makeId(r, c, "rowLbl")

      -- Cell background
      self.gridCanvas[idx] = {
        id = rectId,
        type = "rectangle",
        action = "fill",
        frame = cellRect,
        fillColor = COLOR.cellBG,
        strokeColor = COLOR.border,
        strokeWidth = 1,
        roundedRectRadii = { xRadius = obj.cornerRadius, yRadius = obj.cornerRadius },
      }
      idx = idx + 1

      -- Title text
      local titleText
      if r == 1 and c == 1 then
        titleText = "➕ Add new item"
      else
        local mapIdx = self._cellItemIndex[r][c]
        titleText = (mapIdx and self.items[mapIdx] and self.items[mapIdx].title) or ""
      end

      self.gridCanvas[idx] = {
        id = titleId,
        type = "text",
        frame = {
          x = cellRect.x + self.cellPadding,
          y = cellRect.y + self.cellPadding,
          w = cellRect.w - (self.cellPadding * 2),
          h = cellRect.h - (self.cellPadding * 2)
        },
        text = titleText,
        textFont = ".AppleSystemUIFont",
        textSize = self.titleFontSize,
        textColor = COLOR.title,
        textAlignment = "left",
      }
      idx = idx + 1

      -- Column letter (left), yellow by default
      self.gridCanvas[idx] = {
        id = colId,
        type = "text",
        frame = {
          x = cellRect.x + 6,
          y = cellRect.y + cellRect.h - (self.hintFontSize + 6),
          w = cellRect.w / 2 - 8,
          h = self.hintFontSize + 2
        },
        text = COLS[c],
        textFont = ".AppleSystemUIFont",
        textSize = self.hintFontSize,
        textColor = COLOR.identY,
        textAlignment = "left",
      }
      idx = idx + 1

      -- Row letter (right), yellow (fades with column if not selected)
      self.gridCanvas[idx] = {
        id = rowId,
        type = "text",
        frame = {
          x = cellRect.x + cellRect.w / 2,
          y = cellRect.y + cellRect.h - (self.hintFontSize + 6),
          w = cellRect.w / 2 - 8,
          h = self.hintFontSize + 2
        },
        text = ROWS[r],
        textFont = ".AppleSystemUIFont",
        textSize = self.hintFontSize,
        textColor = COLOR.identY,
        textAlignment = "right",
      }
      idx = idx + 1

      self._cells[r][c] = {
        rectId = rectId, titleId = titleId, colLblId = colId, rowLblId = rowId,
        frame = cellRect,
      }
    end
  end

  -- Footer canvas (below grid)
  self.footerCanvas = canvas.new(ff):level("overlay")
  self.footerCanvas[1] = {
    id = "footerBG",
    type = "rectangle",
    action = "fill",
    frame = { x = 0, y = 0, w = ff.w, h = ff.h },
    fillColor = COLOR.footerBG,
    strokeColor = COLOR.border,
    strokeWidth = 1,
    roundedRectRadii = { xRadius = 10, yRadius = 10 },
  }
  self.footerCanvas[2] = {
    id = "footerText",
    type = "text",
    frame = { x = 0, y = 0, w = ff.w, h = ff.h },
    text = "", -- set below
    textFont = ".AppleSystemUIFont",
    textSize = 13,
    textColor = COLOR.footerTx,
    textAlignment = "center",
  }

  self:_updateFooterText()
end

--------------------------------------------------------------------------------
-- Visual state (fading columns, blue letters)
--------------------------------------------------------------------------------

function obj:_setColumnVisualState()
  if not self.gridCanvas then return end
  for r = 1, self.gridRows do
    for c = 1, self.gridCols do
      local ids = self._cells[r][c]
      local isSelectedCol = (self._selectedCol == c)
      local faded = (self._selectedCol and not isSelectedCol)
      local alpha = faded and self.fadeAlpha or 1.0

      -- Cell background
      self.gridCanvas[ids.rectId].fillColor = {
        white = isSelectedCol and COLOR.cellHi.white or COLOR.cellBG.white,
        alpha = (isSelectedCol and COLOR.cellHi.alpha or COLOR.cellBG.alpha) * alpha,
      }

      -- Title fade
      local baseAlpha = COLOR.title.alpha or 0.95
      self.gridCanvas[ids.titleId].textColor = { white = COLOR.title.white, alpha = baseAlpha * alpha }

      -- Column letter color: blue for selected column, yellow otherwise; respects fade
      local colColor = isSelectedCol and COLOR.identB or COLOR.identY
      self.gridCanvas[ids.colLblId].textColor = {
        red = colColor.red, green = colColor.green, blue = colColor.blue, alpha = colColor.alpha * alpha
      }

      -- Row letter: yellow, but fades with non-selected columns
      self.gridCanvas[ids.rowLblId].textColor = {
        red = COLOR.identY.red, green = COLOR.identY.green, blue = COLOR.identY.blue, alpha = COLOR.identY.alpha * alpha
      }
    end
  end
end

--------------------------------------------------------------------------------
-- Footer text (normal vs delete mode)
--------------------------------------------------------------------------------

function obj:_updateFooterText()
  if not self.footerCanvas then return end
  if self._deleteMode then
    self.footerCanvas["footerBG"].fillColor  = COLOR.footerBGDel
    self.footerCanvas["footerText"].text     = "DELETE MODE — press X to cancel"
    self.footerCanvas["footerText"].textColor= COLOR.footerTxDel
  else
    self.footerCanvas["footerBG"].fillColor  = COLOR.footerBG
    local txt = string.format("Page %d / %d", self._currentPage, self._totalPages)
    self.footerCanvas["footerText"].text     = txt
    self.footerCanvas["footerText"].textColor= COLOR.footerTx
  end
end

--------------------------------------------------------------------------------
-- Overlay helpers (compatible with all Hammerspoon builds)
--------------------------------------------------------------------------------

-- Helper: manually find element index by id (for older Hammerspoon builds)
local function findElementIndex(c, id)
  if not c or not id then return nil end
  for i = 1, #c do
    if c[i].id == id then return i end
  end
  return nil
end

function obj:_ensureDeleteOverlay()
  if not self.gridCanvas then return end
  -- Remove any existing overlay first to avoid duplicates
  local idx = findElementIndex(self.gridCanvas, self._deleteOverlayId)
  if idx then self.gridCanvas:removeElement(idx) end
  local gf = self.gridCanvas:frame()
  self.gridCanvas[#self.gridCanvas + 1] = {
    id = self._deleteOverlayId,
    type = "rectangle",
    action = "fill",
    frame = { x = 0, y = 0, w = gf.w, h = gf.h },
    fillColor = COLOR.delOverlay,
    roundedRectRadii = { xRadius = 14, yRadius = 14 },
  }
  -- Appended last → sits on top; no orderAbove needed
end

function obj:_removeDeleteOverlay()
  if not self.gridCanvas then return end
  local idx = findElementIndex(self.gridCanvas, self._deleteOverlayId)
  if idx then self.gridCanvas:removeElement(idx) end
end

function obj:_enterDeleteMode()
  if not self.gridCanvas then return end
  self._deleteMode = true
  self:_ensureDeleteOverlay()
  self:_updateFooterText()
end

function obj:_exitDeleteMode()
  if not self.gridCanvas then return end
  self._deleteMode = false
  self:_removeDeleteOverlay()
  self:_updateFooterText()
end

function obj:_toggleDeleteMode()
  if not self.gridCanvas then return end
  if self._deleteMode then
    self:_exitDeleteMode()
  else
    self:_enterDeleteMode()
  end
end

-- Soft pulse flash on a cell (fade in then fade out quickly)
function obj:_flashCell(r, c)
  if not self.gridCanvas then return end
  local cell = self._cells and self._cells[r] and self._cells[r][c]
  if not cell then return end
  local frame = cell.frame
  local flashId = string.format("flash_%d_%d", r, c)

  -- start invisible
  self.gridCanvas[#self.gridCanvas + 1] = {
    id = flashId,
    type = "rectangle",
    action = "fill",
    frame = frame,
    fillColor = { red = COLOR.delFlash.red, green = COLOR.delFlash.green, blue = COLOR.delFlash.blue, alpha = 0.0 },
    roundedRectRadii = { xRadius = obj.cornerRadius, yRadius = obj.cornerRadius },
  }

  -- pulse in
  timer.doAfter(0.01, function()
    if self.gridCanvas and self.gridCanvas[flashId] then
      self.gridCanvas[flashId].fillColor = COLOR.delFlash
    end
  end)
  -- pulse out
  timer.doAfter(0.12, function()
    if self.gridCanvas and self.gridCanvas[flashId] then
      self.gridCanvas[flashId].fillColor = { red = COLOR.delFlash.red, green = COLOR.delFlash.green, blue = COLOR.delFlash.blue, alpha = 0.0 }
    end
  end)
  -- cleanup
  timer.doAfter(0.22, function()
    if self.gridCanvas then
      local idx = findElementIndex(self.gridCanvas, flashId)
      if idx then self.gridCanvas:removeElement(idx) end
    end
  end)
end

--------------------------------------------------------------------------------
-- Page change (with quick crossfade)
--------------------------------------------------------------------------------

function obj:_refreshPageContents()
  -- Recompute mapping for current page and update titles
  self:_assignItemsToCellsForPage(self._currentPage)
  for r = 1, self.gridRows do
    for c = 1, self.gridCols do
      local ids = self._cells[r][c]
      if r == 1 and c == 1 then
        self.gridCanvas[ids.titleId].text = "➕ Add new item"
      else
        local mapIdx = self._cellItemIndex[r][c]
        local title = (mapIdx and self.items[mapIdx] and self.items[mapIdx].title) or ""
        self.gridCanvas[ids.titleId].text = title
      end
    end
  end
  self:_updateFooterText()
end

function obj:_changePage(delta)
  if self._totalPages <= 1 then return end

  -- reset column selection when paging
  self._selectedCol = nil
  self:_setColumnVisualState()

  -- wrap pages
  local newPage = self._currentPage + delta
  if newPage < 1 then newPage = self._totalPages end
  if newPage > self._totalPages then newPage = 1 end
  self._currentPage = newPage

  -- crossfade grid + footer
  if self.gridCanvas then self.gridCanvas:hide(self.pageAnim) end
  if self.footerCanvas then self.footerCanvas:hide(self.pageAnim) end

  timer.doAfter(self.pageAnim + 0.01, function()
    self:_refreshPageContents()
    self:_setColumnVisualState()
    if self.gridCanvas then self.gridCanvas:show(self.pageAnim) end
    if self.footerCanvas then self.footerCanvas:show(self.pageAnim) end
    -- If delete mode is active, ensure overlay is still present and on top
    if self._deleteMode then
      self:_ensureDeleteOverlay()
    end
  end)
end

--------------------------------------------------------------------------------
-- Show / Hide (with snappy fades)
--------------------------------------------------------------------------------

function obj:_showCanvases()
  if self.bgCanvas     then self.bgCanvas:show(self.animDuration) end
  if self.gridCanvas   then self.gridCanvas:show(self.animDuration) end
  if self.footerCanvas then self.footerCanvas:show(self.animDuration) end
end

function obj:_hideCanvasesAndDelete()
  if self.bgCanvas     then self.bgCanvas:hide(self.animDuration) end
  if self.gridCanvas   then self.gridCanvas:hide(self.animDuration) end
  if self.footerCanvas then self.footerCanvas:hide(self.animDuration) end

  timer.doAfter(self.animDuration + 0.02, function()
    if self.bgCanvas     then self.bgCanvas:delete();     self.bgCanvas     = nil end
    if self.gridCanvas   then self.gridCanvas:delete();   self.gridCanvas   = nil end
    if self.footerCanvas then self.footerCanvas:delete(); self.footerCanvas = nil end
  end)
end

function obj:_openCanvas()
  self:_captureFront()
  self._currentPage = 1
  self:_buildCanvases()
  self._selectedCol = nil
  self:_setColumnVisualState()
  self:_showCanvases()
  self:_startKeyWatcher()
end

function obj:_closeCanvas()
  if self._keysTap then self._keysTap:stop(); self._keysTap = nil end
  self:_hideCanvasesAndDelete()
  -- Always exit delete mode on close (so new open is clean)
  self._deleteMode = false
end

--------------------------------------------------------------------------------
-- Selection handling
--------------------------------------------------------------------------------

local function charToCol(ch)
  local c = string.lower(ch)
  if c == "a" then return 1 end
  if c == "b" then return 2 end
  if c == "c" then return 3 end
  return nil
end

local function charToRow(ch)
  local c = string.lower(ch)
  if c == "a" then return 1 end
  if c == "b" then return 2 end
  if c == "c" then return 3 end
  if c == "d" then return 4 end
  if c == "e" then return 5 end
  return nil
end

function obj:_activateCell(r, c)
  if self._deleteMode then
    -- A,A does nothing in delete mode
    if r == 1 and c == 1 then return end

    local idx = self._cellItemIndex[r] and self._cellItemIndex[r][c]
    if idx and self.items[idx] then
      self:_flashCell(r, c)        -- soft pulse
      self:deleteItemByIndex(idx)  -- delete from file & memory, recompute pages

      -- adjust current page if we deleted the last item on the last page, etc.
      if self._currentPage > self._totalPages then
        self._currentPage = self._totalPages
      end

      -- refresh mapping & titles for (possibly new) current page
      self:_assignItemsToCellsForPage(self._currentPage)
      self:_refreshPageContents()

      -- Reset column selection and clear highlight so next press starts fresh
      self._selectedCol = nil
      self:_setColumnVisualState()

      -- keep delete mode active; ensure overlay present
      self:_ensureDeleteOverlay()
    end
    return
  end

  -- Normal mode: perform action (paste or add)
  -- Start fade-out immediately (parallel), then perform
  self:_closeCanvas()

  if r == 1 and c == 1 then
    -- Add new item
    self:_restoreFront()
    timer.doAfter(0.02, function()
      self:showAddDialog()
    end)
    return
  end

  -- Normal cell
  local idx = self._cellItemIndex[r] and self._cellItemIndex[r][c]
  if not idx or not self.items[idx] then
    self:_restoreFront()
    alert(string.format("PasteLibrary: No item in %s,%s", COLS[c], ROWS[r]))
    return
  end

  local body = self.items[idx].body or ""
  self:_restoreFront()
  self:_performPaste(body)
end

--------------------------------------------------------------------------------
-- Key watcher
--------------------------------------------------------------------------------

-- Arrow key codes on macOS:
local KEY_LEFT  = 123
local KEY_RIGHT = 124
local KEY_ESC   = 53

function obj:_startKeyWatcher()
  if self._keysTap then self._keysTap:stop(); self._keysTap = nil end

  self._keysTap = eventtap.new({ eventtap.event.types.keyDown }, function(ev)
    local ch = ev:getCharacters()
    local lower = ch and string.lower(ch) or nil
    local keyCode = ev:getKeyCode()

    -- Close on Q / Esc
    if (lower == "q") or (keyCode == KEY_ESC) then
      self:_closeCanvas()
      return true
    end

    -- Toggle Delete Mode on 'x'
    if lower == "x" then
      self:_toggleDeleteMode()
      return true
    end

    -- Page navigation: Right or 'j' => next; Left or 'k' => prev
    if keyCode == KEY_RIGHT or lower == "j" then
      self:_changePage(1)
      return true
    end
    if keyCode == KEY_LEFT or lower == "k" then
      self:_changePage(-1)
      return true
    end

    -- Column selection first
    if not self._selectedCol and lower then
      local c = charToCol(lower)
      if c then
        self._selectedCol = c
        self:_setColumnVisualState()
        return true
      end
      return true -- swallow others while active
    end

    -- Row selection
    if lower then
      local r = charToRow(lower)
      if r then
        self:_activateCell(r, self._selectedCol)
        return true
      end
    end

    return true
  end)

  self._keysTap:start()
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function obj:showGrid()
  self:_openCanvas()
end

function obj:start()
  self:loadItems()
  self:_computePaging()
  return self
end

function obj:bindHotkeys(mapping)
  local def = {
    show = hs.fnutils.partial(self.showGrid, self),
    add  = hs.fnutils.partial(self.showAddDialog, self),
  }
  hs.spoons.bindHotkeysToSpec(def, mapping)
  return self
end

--------------------------------------------------------------------------------
-- Add dialog (kept at end for readability)
--------------------------------------------------------------------------------

function obj:showAddDialog()
  local btn, title = dialog.textPrompt(
    "PasteLibrary: New Item",
    "Enter the Title (the Body will be asked next):",
    "",
    "OK",
    "Cancel"
  )
  if btn ~= "OK" then return end
  if not title or title == "" then
    alert("PasteLibrary: Title is required.")
    return
  end

  local btn2, body = dialog.textPrompt(
    "PasteLibrary: Body",
    "Enter the Body text (multiline supported):",
    "",
    "Save",
    "Cancel"
  )
  if btn2 ~= "Save" then return end
  body = body or ""

  self:addItem(title, body)
  alert("PasteLibrary: Saved \"" .. title .. "\"")
end

return obj

