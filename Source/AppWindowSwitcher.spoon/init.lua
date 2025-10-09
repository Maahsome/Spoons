-- Copyright (c) 2025 Christopher Maahs
-- MIT License

local obj = {}
obj.__index = obj

obj.name = "AppWindowSwitcher"
obj.version = "2.2"
obj.author = "Christopher Maahs <cmaahs@gmail.com>"
obj.license = "MIT"

obj.hotkey = { mods = {"command", "alt"}, key = "w" }

-- === visuals ===
local backgroundAlpha = 0.85
local fadeTime = 0.15
local fadeDuration = 0.25
local highlightColor = { red = 0.2, green = 0.6, blue = 1.0, alpha = 0.8 }
local columnHighlight = { red = 0.2, green = 0.6, blue = 1.0, alpha = 0.15 }
local yellowColor = { red = 1.0, green = 1.0, blue = 0.2, alpha = 1.0 }

-- === internal state ===
local windows = {}
local canvas = nil
local keyTap = nil
local appIcon = nil
local selectedColumn = nil
local selectedRow = nil

local columns = { "A", "B", "C" }
local rows = { "A", "B", "C", "D", "E" }

------------------------------------------------------------
-- helpers
------------------------------------------------------------
local function truncateText(txt, max)
    if #txt > max then return txt:sub(1, max - 3) .. "..." end
    return txt
end

local function gridIndex(col, row)
    local colIndex = hs.fnutils.indexOf(columns, col)
    local rowIndex = hs.fnutils.indexOf(rows, row)
    if not colIndex or not rowIndex then return nil end
    return (colIndex - 1) * #rows + rowIndex
end

-- === fade helper ===
local function fadeUnselectedColumns(selected)
    if not canvas then return end
    local totalCols, totalRows = #columns, #rows
    for c = 1, totalCols do
        if columns[c] ~= selected then
            for r = 1, totalRows do
                local idx = gridIndex(columns[c], rows[r])
                local baseIndex = 4 + ((c - 1) * totalRows + (r - 1)) * 4
                -- rectangle, title, col letter, row letter
                for i = baseIndex + 1, baseIndex + 4 do
                    local e = canvas[i]
                    if e then
                        hs.canvas.transition(canvas, i, {
                            alpha = 0.3,
                            time = fadeDuration,
                            style = "linear"
                        })
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
function obj:showWindowChooser()
    local fw = hs.window.focusedWindow()
    if not fw then hs.alert.show("No focused window") return end

    local app = fw:application()
    if not app then hs.alert.show("Could not get application") return end

    local appName = app:name()
    appIcon = hs.image.imageFromAppBundle(app:bundleID())
    windows = app:allWindows()

    table.sort(windows, function(a, b)
        return a:title():lower() < b:title():lower()
    end)

    if #windows == 0 then
        hs.alert.show("No windows found")
        return
    end

    selectedColumn, selectedRow = nil, nil
    self:showCanvas(appName)
end

------------------------------------------------------------
function obj:showCanvas(appName)
    local screen = hs.screen.mainScreen()
    if not screen then return end
    local sFrame = screen:frame()
    local width = sFrame.w * 2 / 3
    if width > 1600 then width = 1600 end
    local height = 620
    local cx = sFrame.x + (sFrame.w - width) / 2
    local cy = sFrame.y + (sFrame.h - height) / 2

    canvas = hs.canvas.new({ x = cx, y = cy, w = width, h = height })
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    canvas:replaceElements({
        {
            type = "rectangle",
            fillColor = { white = 0.05, alpha = backgroundAlpha },
            roundedRectRadii = { xRadius = 10, yRadius = 10 },
            frame = { x = 0, y = 0, w = width, h = height }
        },
        {
            type = "image",
            image = appIcon,
            frame = { x = 20, y = 20, w = 48, h = 48 }
        },
        {
            type = "text",
            text = appName,
            textColor = { white = 1 },
            textSize = 22,
            frame = { x = 80, y = 28, w = width - 100, h = 40 }
        }
    })

    self:drawGrid(width, height)
    canvas:show(fadeTime)
    canvas:orderAbove(nil)

    ------------------------------------------------------------
    -- Key handler
    ------------------------------------------------------------
    keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
        local key = hs.keycodes.map[e:getKeyCode()]
        key = key and string.upper(key) or ""

        if key == "Q" then
            obj:close()
            return true
        end

        if not selectedColumn then
            if hs.fnutils.contains(columns, key) then
                selectedColumn = key
                obj:drawGrid(width, height)
                hs.timer.doAfter(0.1, function()
                    fadeUnselectedColumns(selectedColumn)
                end)
                return true
            end
        else
            if hs.fnutils.contains(rows, key) then
                selectedRow = key
                local idx = gridIndex(selectedColumn, selectedRow)
                obj:close()
                local win = windows[idx]
                if win then
                    hs.timer.doAfter(0.05, function()
                        win:application():activate(true)
                        win:focus()
                        win:raise()
                    end)
                end
                return true
            end
        end
        return false
    end)
    keyTap:start()
end

------------------------------------------------------------
function obj:drawGrid(width, height)
    if not canvas then return end
    while #canvas > 3 do canvas[#canvas] = nil end

    local totalCols, totalRows = #columns, #rows
    local margin = 20
    local cellW = (width - (margin * (totalCols + 2))) / totalCols
    local cellH = 80
    local startX, startY = margin * 2, 100

    -- Draw grid cells
    for c = 1, totalCols do
        for r = 1, totalRows do
            local x = startX + (c - 1) * (cellW + margin)
            local y = startY + (r - 1) * (cellH + margin)
            local idx = gridIndex(columns[c], rows[r])
            if idx <= #windows then
                local title = truncateText(windows[idx]:title(), 30)
                local isSelectedCol = (selectedColumn == columns[c])
                local isSelectedCell = (selectedColumn == columns[c] and selectedRow == rows[r])

                local fill
                if isSelectedCell then
                    fill = { red = 0.2, green = 0.6, blue = 1.0, alpha = 0.4 }
                elseif isSelectedCol then
                    fill = columnHighlight
                else
                    fill = { white = 0.1, alpha = 0.3 }
                end

                local colColor = yellowColor
                local rowColor = yellowColor
                if selectedColumn == columns[c] then colColor = highlightColor end
                if selectedRow == rows[r] then rowColor = highlightColor end

                canvas:appendElements({
                    {
                        type = "rectangle",
                        fillColor = fill,
                        roundedRectRadii = { xRadius = 8, yRadius = 8 },
                        frame = { x = x, y = y, w = cellW, h = cellH }
                    },
                    {
                        type = "text",
                        text = title,
                        textColor = { white = 1 },
                        textSize = 16,
                        frame = { x = x + 25, y = y + (cellH / 2 - 8), w = cellW - 50, h = cellH }
                    },
                    {
                        type = "text",
                        text = columns[c],
                        textColor = colColor,
                        textSize = 18,
                        frame = { x = x + 5, y = y + (cellH / 2 - 10), w = 20, h = 20 }
                    },
                    {
                        type = "text",
                        text = rows[r],
                        textColor = rowColor,
                        textSize = 18,
                        frame = { x = x + cellW - 25, y = y + (cellH / 2 - 10), w = 20, h = 20 }
                    }
                })
            end
        end
    end
end

------------------------------------------------------------
function obj:close()
    if keyTap then keyTap:stop(); keyTap = nil end
    if canvas then
        canvas:hide(fadeTime)
        hs.timer.doAfter(fadeTime, function()
            canvas:delete()
            canvas = nil
        end)
    end
end

------------------------------------------------------------
function obj:bindHotkey()
    hs.hotkey.bind(self.hotkey.mods, self.hotkey.key, function()
        self:showWindowChooser()
    end)
end

return obj
