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

--- === AppWindowSwitcher ===
---
--- With this Spoon you will be prompted with a list of all open windows of the currently focused application.
--- Official homepage for more info and documentation:
--- [https://github.com/Maahsome/Spoons](https://github.com/Maahsome/Spoons)
---
local obj = {}
obj.__index = obj

obj.name = "AppWindowSwitcher"
obj.version = "2.1"
obj.author = "Christopher Maahs <cmaahs@gmail.com>"
obj.license = "MIT"

obj.hotkey = { mods = {"command", "alt"}, key = "w" }

-- === configurable visuals ===
local visibleRows        = 8
local lineHeight         = 30
local maxTextLength      = 45
local backgroundAlpha    = 0.6   -- main dialog opacity
local dimBackgroundAlpha = 0.4   -- full-screen dim layer opacity
local highlightColor     = { red = 0.2, green = 0.6, blue = 1.0, alpha = 0.8 }
local fadeTime           = 0.15
local animationDuration  = 0.08

-- === internal state ===
local currentIndex = 1
local windows      = {}
local canvas       = nil
local appIcon      = nil
local keyTap       = nil
local scrollOffset = 0
local animating    = false

-- ------------------------------------------------------------
local function truncateText(txt, max)
    if #txt > max then return txt:sub(1, max - 3) .. "..." end
    return txt
end
-- ------------------------------------------------------------

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

    if #windows == 0 then hs.alert.show("No windows found") return end
    currentIndex, scrollOffset = 1, 0
    self:showCanvas(appName)
end

-- ------------------------------------------------------------
-- create multi-monitor-safe canvas covering every display
local function makeGlobalCanvas()
    local allScreens = hs.screen.allScreens()
    local minX, minY =  1e9,  1e9
    local maxX, maxY = -1e9, -1e9
    for _, s in ipairs(allScreens) do
        local f = s:fullFrame()
        minX = math.min(minX, f.x)
        minY = math.min(minY, f.y)
        maxX = math.max(maxX, f.x + f.w)
        maxY = math.max(maxY, f.y + f.h)
    end
    local frame = { x = minX, y = minY, w = maxX - minX, h = maxY - minY }
    return hs.canvas.new(frame), frame, minX, minY
end
-- ------------------------------------------------------------
function obj:showCanvas(appName)
    local screen      = hs.screen.mainScreen()
    if not screen then hs.alert.show("No screen") return end
    local screenFrame = screen:frame()
    local width, height = 500, 350

    -- create a normal canvas only as big as the chooser window
    local centerX = screenFrame.x + (screenFrame.w - width) / 2
    local centerY = screenFrame.y + (screenFrame.h - height) / 2

    canvas = hs.canvas.new({ x = centerX, y = centerY, w = width, h = height })
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

    -- main rounded chooser window (no fullscreen dim)
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
            textSize = 20,
            frame = { x = 80, y = 28, w = 380, h = 40 }
        }
    })

    -- draw the initial list inside this window
    self:updateCanvasText(centerX, centerY)

    canvas:show(fadeTime)
    canvas:orderAbove(nil)

    -- capture navigation keys
    keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
        if animating then return true end
        local key = hs.keycodes.map[e:getKeyCode()]
        if     key == "j"      then obj:moveDown();  return true
        elseif key == "k"      then obj:moveUp();    return true
        elseif key == "return" then obj:activateSelected(); return true
        elseif key == "escape" then obj:close();     return true end
        return false
    end)
    keyTap:start()
end

-- ------------------------------------------------------------
function obj:updateCanvasText()
    if not canvas then return end

    -- remove old list (keep background + icon + title)
    while #canvas > 3 do canvas[#canvas] = nil end

    local yOffset = 80
    for i = 1, #windows do
        local isSel = (i == currentIndex)
        local displayIndex = i - scrollOffset
        if displayIndex >= 1 and displayIndex <= visibleRows then
            local yPos = yOffset + (displayIndex - 1) * (lineHeight + 4)

            if isSel then
                canvas:appendElements({
                    {
                        type  = "rectangle",
                        action = "fill",
                        fillColor = highlightColor,
                        roundedRectRadii = { xRadius = 6, yRadius = 6 },
                        frame = { x = 15, y = yPos - 2, w = 470, h = lineHeight }
                    }
                })
            end

            canvas:appendElements({
                {
                    type = "text",
                    text = truncateText(windows[i]:title(), maxTextLength),
                    textColor = isSel and { white = 0 } or { white = 1 },
                    textSize = 16,
                    frame = { x = 25, y = yPos + 4, w = 450, h = lineHeight }
                }
            })
        end
    end
end
-- ------------------------------------------------------------

function obj:moveDown()
    local newIndex = (currentIndex % #windows) + 1
    self:animateHighlightChange(newIndex)
end
function obj:moveUp()
    local newIndex = (currentIndex - 2) % #windows + 1
    self:animateHighlightChange(newIndex)
end

function obj:animateHighlightChange(newIndex)
    animating = true
    local oldIndex = currentIndex
    currentIndex = newIndex

    if currentIndex == 1 and oldIndex == #windows then
        scrollOffset = 0
    elseif currentIndex == #windows and oldIndex == 1 then
        scrollOffset = math.max(#windows - visibleRows, 0)
    elseif currentIndex - scrollOffset > visibleRows then
        scrollOffset = scrollOffset + 1
    elseif currentIndex <= scrollOffset then
        scrollOffset = math.max(currentIndex - 1, 0)
    end

    -- we don’t recreate or replace the canvas, only redraw the list
    local s  = hs.screen.mainScreen():frame()
    local cx = s.x + (s.w - 500) / 2 - (minX or 0)
    local cy = s.y + (s.h - 350) / 2 - (minY or 0)

    local frames = 10
    local step   = 1 / frames
    local p      = 0
    local timer
    timer = hs.timer.doEvery(animationDuration / frames, function()
        p = p + step
        if p >= 1 then
            if timer then timer:stop() end
            animating = false
        end
        obj:updateCanvasText(cx, cy)
    end)
end
-- ------------------------------------------------------------
function obj:activateSelected()
    local win = windows[currentIndex]
    obj:close()
    if win and win:application() then
        hs.timer.doAfter(0.05, function()
            win:application():activate(true)
            win:focus()
            win:raise()
        end)
    end
end
-- ------------------------------------------------------------
function obj:close()
    if keyTap then keyTap:stop(); keyTap = nil end
    if canvas then
        canvas:hide(fadeTime)
        hs.timer.doAfter(fadeTime, function() canvas:delete() end)
    end
end
-- ------------------------------------------------------------
function obj:bindHotkey()
    hs.hotkey.bind(self.hotkey.mods, self.hotkey.key, function()
        self:showWindowChooser()
    end)
end

return obj
