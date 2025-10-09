-- Copyright (c) 2025 Christopher Maahs
-- MIT License

--- === AppLauncherSwitcher ===
---
--- Grid-based app launcher/switcher combining Dock and running applications.
---
local obj = {}
obj.__index = obj

obj.name = "AppLauncherSwitcher"
obj.version = "1.1"
obj.author = "Christopher Maahs <cmaahs@gmail.com>"
obj.license = "MIT"

------------------------------------------------------------
-- Configurable properties
------------------------------------------------------------
obj.preferredScreenName = nil -- set via :setPreferredScreen(name)
obj.fadeDuration = 0.15       -- seconds for fade animation
obj.dimAlpha = 0.35           -- opacity for non-selected columns

------------------------------------------------------------
-- Logger
------------------------------------------------------------
local logger = hs.logger.new(obj.name)
obj._logger = logger

------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------
local dockPlist = os.getenv("HOME") .. "/Library/Preferences/com.apple.dock.plist"

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
-- Running apps via window filter
------------------------------------------------------------
local visibleWindowFilter = hs.window.filter.new()
    :setDefaultFilter{}
    :setOverrideFilter({ visible = true })

local runningAppsCache = {}

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
end

refreshRunningApps()
visibleWindowFilter:subscribe({
    hs.window.filter.windowCreated,
    hs.window.filter.windowDestroyed,
    hs.window.filter.windowUnhidden,
    hs.window.filter.windowHidden,
    hs.window.filter.windowMinimized,
    hs.window.filter.windowUnminimized,
}, function() hs.timer.doAfter(0.5, refreshRunningApps) end)

------------------------------------------------------------
-- Public API
------------------------------------------------------------
function obj:setPreferredScreen(name)
    self.preferredScreenName = name
    self._logger.i(string.format("Preferred screen set to: %s", name))
end

------------------------------------------------------------
-- Grid UI
------------------------------------------------------------
local gridRows, gridCols = 10, 10
local keyRows = {"A","B","C","D","E","F","G","H","I","J"}
local keyCols = keyRows

function obj:showGrid()
    --------------------------------------------------------
    -- Determine target screen
    --------------------------------------------------------
    local screen = hs.screen.mainScreen()
    if self.preferredScreenName then
        for _, s in ipairs(hs.screen.allScreens()) do
            if s:name() == self.preferredScreenName then
                screen = s
                break
            end
        end
    end
    if not screen then screen = hs.screen.mainScreen() end

    local frame  = screen:frame()
    local cw, ch = frame.w * 0.66, frame.h * 0.8
    local x0, y0 = frame.x + (frame.w - cw) / 2, frame.y + (frame.h - ch) / 2

    --------------------------------------------------------
    -- Gather apps
    --------------------------------------------------------
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
    local cellW, cellH = cw / gridCols, ch / gridRows

    --------------------------------------------------------
    -- Canvas setup
    --------------------------------------------------------
    local canvas = hs.canvas.new{ x = x0, y = y0, w = cw, h = ch }
    canvas:level(hs.canvas.windowLevels.mainMenu + 1)
    canvas:alpha(0.95)
    canvas:show()

    canvas[#canvas + 1] = {
        type = "rectangle",
        action = "fill",
        fillColor = {white = 0.05, alpha = 0.95},
        roundedRectRadii = {xRadius = 10, yRadius = 10},
    }

    --------------------------------------------------------
    -- Draw grid
    --------------------------------------------------------
    for i = 1, total do
        local app = apps[i]
        local r = math.floor((i - 1) / gridCols) + 1
        local c = ((i - 1) % gridCols) + 1
        local x, y = (c - 1) * cellW, (r - 1) * cellH

        if hs.application.get(app.bundleID) then
            canvas[#canvas + 1] = {
                type = "rectangle",
                action = "fill",
                fillColor = {red = 0.2, green = 0.4, blue = 1, alpha = 0.1},
                frame = {x = x + 4, y = y + 4, w = cellW - 8, h = cellH - 8},
            }
        end

        canvas[#canvas + 1] = {
            type = "image",
            image = app.image,
            frame = {x = x + cellW * 0.35, y = y + 10, w = cellW * 0.3, h = cellW * 0.3},
            imageScaling = "scaleToFit",
        }

        canvas[#canvas + 1] = {
            type = "text",
            text = app.text,
            textSize = 13,
            textColor = {white = 1},
            frame = {x = x + 2, y = y + cellH - 30, w = cellW - 4, h = 24},
            textAlignment = "center",
        }

        local colLetter = keyCols[c]
        local rowLetter = keyRows[r]

        canvas[#canvas + 1] = {
            id = string.format("colLetter_%d_%d", r, c),
            type = "text",
            text = colLetter,
            textSize = 20,
            textColor = {red = 1, green = 1, blue = 0},
            frame = {x = x + 10, y = y + 8, w = 20, h = 20},
            textAlignment = "left",
        }
        canvas[#canvas + 1] = {
            id = string.format("rowLetter_%d_%d", r, c),
            type = "text",
            text = rowLetter,
            textSize = 20,
            textColor = {red = 1, green = 1, blue = 0},
            frame = {x = x + cellW - 25, y = y + 8, w = 20, h = 20},
            textAlignment = "right",
        }
    end

    --------------------------------------------------------
    -- Fade animation helper
    --------------------------------------------------------
    local function animateFade(targetCol, duration, endAlpha)
        local steps = 15
        local interval = duration / steps
        local currentStep = 0
        local overlayId = string.format("fadeOverlay_%d", targetCol)

        local overlay = {
            id = overlayId,
            type = "rectangle",
            action = "fill",
            fillColor = {white = 0, alpha = 0},
            frame = {x = (targetCol - 1) * cellW, y = 0, w = cellW, h = ch},
        }
        canvas[#canvas + 1] = overlay

        local timer
        timer = hs.timer.doEvery(interval, function()
            currentStep = currentStep + 1
            local alpha = (endAlpha / steps) * currentStep
            if alpha > endAlpha then alpha = endAlpha end
            canvas[overlayId].fillColor = {white = 0, alpha = alpha}
            if currentStep >= steps then timer:stop() end
        end)
    end

    --------------------------------------------------------
    -- Selection logic
    --------------------------------------------------------
    local selectedCol
    local watcher

    local function closeCanvas()
        if watcher then watcher:stop() end
        canvas:delete()
    end

    local function fadeUnselectedColumns(colIdx)
        for c = 1, gridCols do
            if c ~= colIdx then
                -- remove indicators for unselected columns
                local removeIds = {}
                for i, e in ipairs(canvas) do
                    if e.id and (e.id:match(string.format("colLetter_%%d_%d", c))
                        or e.id:match(string.format("rowLetter_%%d_%d", c))) then
                        table.insert(removeIds, i)
                    end
                end
                for i = #removeIds, 1, -1 do
                    canvas:removeElement(removeIds[i])
                end
                -- fade this column
                animateFade(c, obj.fadeDuration, obj.dimAlpha)
            end
        end
    end

    local function highlightColumn(colIdx)
        obj._logger.i("Column selected -> " .. keyCols[colIdx])

        -- turn only the selected column's letters blue
        for i, e in ipairs(canvas) do
            if e.id and e.id:match(string.format("colLetter_%%d_%d", colIdx)) then
                canvas[i].textColor = {red = 0, green = 0.5, blue = 1}
            end
        end

        fadeUnselectedColumns(colIdx)
    end

    watcher = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(evt)
        local char = evt:getCharacters():upper()
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
            obj._logger.i("Row selected -> " .. char)
            local idx = (rowIdx - 1) * gridCols + selectedCol
            local app = apps[idx]
            if app then
                obj._logger.i("Launching app -> " .. app.text)
                launchOrActivate(app)
            end
            closeCanvas()
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
