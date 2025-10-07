-- Copyright (c) 2025 Christopher Maahs
-- Permission is hereby granted, free of charge, to any person obtaining a copy of this
-- software and associated documentation files (the "Software"), to deal in the Software
-- without restriction, including without limitation the rights to use, copy, modify, merge,
-- publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
-- to whom the Software is furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all copies
-- or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
-- INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
-- PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
-- FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
-- OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
-- DEALINGS IN THE SOFTWARE.

--- === AppLauncherSwitcher===
---
--- This spoon is a grid based launcher/switcher for applications.  It uses your Dock applications and running applications as the source.  Apps are chosen using a grid based chording system.
--- Official homepage for more info and documentation:
--- [https://github.com/Maahsome/Spoons](https://github.com/Maahsome/Spoons)
---
local obj = {}
obj.__index = obj

obj.name = "AppLauncherSwitcher"
obj.version = "1.0"
obj.author = "Christopher Maahs <cmaahs@gmail.com>"
obj.license = "MIT"

local dockPlist = os.getenv("HOME") .. "/Library/Preferences/com.apple.dock.plist"
local logger = hs.logger.new(obj.name)
obj._logger = logger

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function decodeURL(str)
    return (str:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

------------------------------------------------------------
-- Dock apps
------------------------------------------------------------
local function getDockApps()
    local choices = {}
    local plist = hs.plist.read(dockPlist)
    if not plist then return choices end

    local apps = plist["persistent-apps"] or {}
    for _, entry in ipairs(apps) do
        local urlData = entry["tile-data"] and entry["tile-data"]["file-data"]
        if urlData and urlData["_CFURLString"] then
            local path = decodeURL(urlData["_CFURLString"]:gsub("^file://", ""))
            if string.match(path, "%.app/?$") and hs.fs.attributes(path) then
                local info = hs.application.infoForBundlePath(path)
                local bundleID = info and info.CFBundleIdentifier
                local name = (info and (info.CFBundleDisplayName or info.CFBundleName))
                              or hs.fs.displayName(path)
                              or path:match("([^/]+)%.app")

                local icon = hs.image.imageFromAppBundle(bundleID)
                            or hs.image.imageFromPath(path .. "/Contents/Resources/AppIcon.icns")
                            or hs.image.imageFromName("NSApplicationIcon")

                table.insert(choices, {
                    text = name,
                    appPath = path,
                    bundleID = bundleID,
                    image = icon,
                })
            end
        end
    end
    return choices
end

------------------------------------------------------------
-- Launch or activate app
------------------------------------------------------------
local function launchOrActivate(app)
    if not app then return end
    if app.bundleID then
        local inst = hs.application.get(app.bundleID)
        if inst and inst:isRunning() then
            inst:activate()
        else
            hs.application.launchOrFocusByBundleID(app.bundleID)
        end
    else
        hs.application.open(app.appPath)
    end
end

------------------------------------------------------------
-- Real-time running app cache via hs.window.filter
------------------------------------------------------------
local visibleWindowFilter = hs.window.filter.new()
    :setDefaultFilter{}
    :setOverrideFilter({
        visible = true,
    })

local runningAppsCache = {}
local seenBundleIDs = {}

local function refreshRunningApps()
    local windows = visibleWindowFilter:getWindows()
    local apps, seen = {}, {}

    for _, win in ipairs(windows) do
        local app = win:application()
        if app then
            local name = app:name()
            local bundleID = app:bundleID()
            if name and bundleID and not seen[bundleID] then
                local lowerName = name:lower()
                if not (
                    lowerName:match("service") or
                    lowerName:match("helper") or
                    lowerName:match("agent") or
                    lowerName:match("daemon") or
                    lowerName:match("windowserver") or
                    bundleID:match("org%.hammerspoon")
                ) then
                    local icon = hs.image.imageFromAppBundle(bundleID)
                                or hs.image.imageFromName("NSApplicationIcon")
                    table.insert(apps, {
                        text = name,
                        appPath = app:path(),
                        bundleID = bundleID,
                        image = icon,
                    })
                    seen[bundleID] = true
                end
            end
        end
    end
    runningAppsCache = apps
    seenBundleIDs = seen
end

-- initialize and subscribe for updates
refreshRunningApps()
visibleWindowFilter:subscribe({
    hs.window.filter.windowCreated,
    hs.window.filter.windowDestroyed,
    hs.window.filter.windowUnhidden,
    hs.window.filter.windowHidden,
    hs.window.filter.windowMinimized,
    hs.window.filter.windowUnminimized,
}, function()
    hs.timer.doAfter(0.5, refreshRunningApps)
end)

------------------------------------------------------------
-- Grid UI
------------------------------------------------------------
local gridRows, gridCols = 10, 10
local keyRows = {"A","B","C","D","E","F","G","H","I","J"}
local keyCols = keyRows

function obj:showGrid()
    local screen = hs.screen.mainScreen()
    local frame  = screen:frame()
    local cw, ch = frame.w * 0.8, frame.h * 0.8
    local x0, y0 = frame.x + (frame.w - cw) / 2, frame.y + (frame.h - ch) / 2

    -- Combine Dock + cached running apps (no duplicates)
    local dockApps = getDockApps()
    local runningApps = runningAppsCache or {}
    local seen, apps = {}, {}

    for _, app in ipairs(dockApps) do
        table.insert(apps, app)
        if app.bundleID then seen[app.bundleID] = true end
    end
    for _, app in ipairs(runningApps) do
        if not seen[app.bundleID] then
            table.insert(apps, app)
            seen[app.bundleID] = true
        end
    end

    local total = math.min(#apps, gridRows * gridCols)
    local headerH = 40
    local cellW, cellH = cw / gridCols, (ch - headerH) / gridRows

    --------------------------------------------------------
    -- Create canvas
    --------------------------------------------------------
    local canvas = hs.canvas.new{ x = x0, y = y0, w = cw, h = ch }
    canvas:level(hs.canvas.windowLevels.mainMenu + 1)
    canvas:alpha(0.95)
    canvas:show()

    -- background
    canvas[#canvas + 1] = {
        type = "rectangle",
        action = "fill",
        fillColor = {white = 0.05, alpha = 0.95},
        roundedRectRadii = {xRadius = 10, yRadius = 10},
    }

    --------------------------------------------------------
    -- Top header row (A–J)
    --------------------------------------------------------
    for c = 1, gridCols do
        local letter = keyCols[c]
        canvas[#canvas + 1] = {
            type = "text",
            text = letter,
            textSize = 20,
            textColor = {white = 0.8},
            frame = {x = (c - 1) * cellW, y = 5, w = cellW, h = headerH - 10},
            textAlignment = "center",
        }
    end

    --------------------------------------------------------
    -- Draw app grid
    --------------------------------------------------------
    for i = 1, total do
        local app = apps[i]
        local r = math.floor((i - 1) / gridCols)
        local c = (i - 1) % gridCols
        local x, y = c * cellW, headerH + r * cellH

        -- subtle tint for running apps
        if hs.application.get(app.bundleID) then
            canvas[#canvas + 1] = {
                type = "rectangle",
                action = "fill",
                fillColor = {red = 0.2, green = 0.4, blue = 1, alpha = 0.1},
                frame = {x = x + 4, y = y + 4, w = cellW - 8, h = cellH - 8},
            }
        end

        -- icon
        canvas[#canvas + 1] = {
            type = "image",
            image = app.image,
            frame = {x = x + cellW * 0.375, y = y + 10, w = cellW * 0.25, h = cellW * 0.25},
            imageScaling = "scaleToFit",
        }

        -- app name
        canvas[#canvas + 1] = {
            type = "text",
            text = app.text,
            textSize = 13,
            textColor = {white = 1},
            frame = {x = x + 2, y = y + cellH - 28, w = cellW - 4, h = 22},
            textAlignment = "center",
        }
    end

    --------------------------------------------------------
    -- Column-first selection logic
    --------------------------------------------------------
    local selectedCol
    local watcher

    local function closeCanvas()
        if watcher then watcher:stop() end
        canvas:delete()
    end

    local function highlightColumn(colIdx)
        canvas[#canvas + 1] = {
            id = "colHighlight",
            type = "rectangle",
            action = "fill",
            fillColor = {red = 0.2, green = 0.4, blue = 1, alpha = 0.15},
            frame = {x = (colIdx - 1) * cellW, y = 0, w = cellW, h = ch},
        }
        for row = 1, gridRows do
            local idx = (row - 1) * gridCols + colIdx
            if idx <= total then
                local label = keyRows[row]
                local y = headerH + (row - 1) * cellH + cellH - 18
                canvas[#canvas + 1] = {
                    type = "text",
                    text = label,
                    textSize = 20,
                    textColor = {red = 0.7, green = 0.8, blue = 1},
                    frame = {x = (colIdx - 1) * cellW + 25, y = y - 65, w = cellW, h = 20},
                    textAlignment = "left",
                }
            end
        end
    end

    watcher = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(evt)
        local char = evt:getCharacters():upper()

        -- Q to close
        if char == "Q" then
            closeCanvas()
            return true
        end

        if not selectedCol and hs.fnutils.contains(keyCols, char) then
            selectedCol = hs.fnutils.indexOf(keyCols, char)
            highlightColumn(selectedCol)
            return true
        elseif selectedCol and hs.fnutils.contains(keyRows, char) then
            local rowIdx = hs.fnutils.indexOf(keyRows, char)
            local idx = (rowIdx - 1) * gridCols + selectedCol
            closeCanvas()
            local app = apps[idx]
            if app then launchOrActivate(app) end
            return true
        end
        return false
    end)
    watcher:start()
end

------------------------------------------------------------
-- Hotkey binder
------------------------------------------------------------
function obj:bindHotKeys(mapping)
    hs.spoons.bindHotkeysToSpec({showGrid = hs.fnutils.partial(self.showGrid, self)}, mapping)
end

return obj
