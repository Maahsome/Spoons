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
obj.version = "2.0"
obj.author = "Christopher Maahs <cmaahs@gmail.com>"
obj.license = "MIT"

obj.hotkey = { mods = {"command", "alt"}, key = "w" }

local currentIndex = 1
local windows = {}
local canvas = nil
local appIcon = nil
local fadeTime = 0.15
local keyTap = nil
local scrollOffset = 0
local visibleRows = 8      -- how many rows fit in the visible area
local lineHeight = 30
local maxTextLength = 45
local highlightColor = {red=0.2, green=0.6, blue=1.0, alpha=0.8}
local animationDuration = 0.08
local animating = false

-- === Helper ===
local function truncateText(text, max)
    if string.len(text) > max then
        return string.sub(text, 1, max - 3) .. "..."
    end
    return text
end

-- === Core ===

function obj:showWindowChooser()
    local frontmostWindow = hs.window.focusedWindow()
    if not frontmostWindow then
        hs.alert.show("No focused window")
        return
    end

    local app = frontmostWindow:application()
    if not app then
        hs.alert.show("Could not get application")
        return
    end

    local appName = app:name()
    appIcon = hs.image.imageFromAppBundle(app:bundleID())

    windows = hs.fnutils.filter(app:allWindows(), function(win)
        return true
    end)

    table.sort(windows, function(a, b)
        return a:title():lower() < b:title():lower()
    end)

    if #windows == 0 then
        hs.alert.show("No windows found")
        return
    end

    currentIndex = 1
    scrollOffset = 0
    self:showCanvas(appName)
end

function obj:showCanvas(appName)
    local screenFrame = hs.screen.mainScreen():frame()
    local width, height = 500, 350
    local x = screenFrame.x + (screenFrame.w - width) / 2
    local y = screenFrame.y + (screenFrame.h - height) / 2

    canvas = hs.canvas.new({x=x, y=y, w=width, h=height})
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

    canvas:replaceElements({
        { type="rectangle", fillColor={white=0.05, alpha=0.9}, roundedRectRadii={xRadius=10, yRadius=10}, frame={x=0, y=0, w=width, h=height} },
        { type="image", image=appIcon, frame={x=20, y=20, w=48, h=48} },
        { type="text", text=appName, textColor={white=1}, textSize=20, frame={x=80, y=28, w=380, h=40} }
    })

    self:updateCanvasText()
    canvas:show(fadeTime)

    -- Capture keys globally using eventtap
    keyTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
        local key = hs.keycodes.map[event:getKeyCode()]
        if animating then return true end  -- ignore rapid keypresses during animation
        if key == "j" then
            obj:moveDown()
            return true
        elseif key == "k" then
            obj:moveUp()
            return true
        elseif key == "return" then
            obj:activateSelected()
            return true
        elseif key == "escape" then
            obj:close()
            return true
        end
        return false
    end)
    keyTap:start()
end

-- === Drawing ===
function obj:updateCanvasText()
    local elements = {
        { type="rectangle", fillColor={white=0.05, alpha=0}, frame={x=0, y=0, w=0, h=0} }, -- dummy base element
        { type="image", image=appIcon, frame={x=20, y=20, w=48, h=48} },
        { type="text", text=windows[1] and windows[1]:application():name() or "", textColor={white=1}, textSize=20, frame={x=80, y=28, w=380, h=40} }
    }

    local yOffset = 80
    for i = 1, #windows do
        local isSel = (i == currentIndex)
        local displayIndex = i - scrollOffset
        if displayIndex >= 1 and displayIndex <= visibleRows then
            local y = yOffset + (displayIndex - 1) * (lineHeight + 4)
            if isSel then
                table.insert(elements, {
                    type="rectangle",
                    action="fill",
                    fillColor=highlightColor,
                    roundedRectRadii={xRadius=6, yRadius=6},
                    frame={x=15, y=y-2, w=470, h=lineHeight}
                })
            end
            table.insert(elements, {
                type="text",
                text=truncateText(windows[i]:title(), maxTextLength),
                textColor=isSel and {white=0} or {white=1},
                textSize=16,
                frame={x=25, y=y+4, w=450, h=lineHeight}
            })
        end
    end
    if canvas then canvas:replaceElements(elements) end
end

-- === Animation + Scrolling ===
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

    -- Handle wrap-around scrolling properly
    if currentIndex == 1 and oldIndex == #windows then
        -- wrapped from bottom → top
        scrollOffset = 0
    elseif currentIndex == #windows and oldIndex == 1 then
        -- wrapped from top → bottom
        scrollOffset = math.max(#windows - visibleRows, 0)
    elseif currentIndex - scrollOffset > visibleRows then
        scrollOffset = scrollOffset + 1
    elseif currentIndex <= scrollOffset then
        scrollOffset = math.max(currentIndex - 1, 0)
    end

    -- Animation parameters
    local frames = 10
    local step = 1 / frames
    local progress = 0
    local timer
    timer = hs.timer.doEvery(animationDuration / frames, function()
        progress = progress + step
        if progress >= 1 then
            if timer then timer:stop() end
            animating = false
            obj:updateCanvasText()
            return
        end
        obj:updateCanvasText()
    end)
end

-- === Window Activation ===
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

-- === Close & Cleanup ===
function obj:close()
    if keyTap then keyTap:stop() keyTap = nil end
    if canvas then
        canvas:hide(fadeTime)
        hs.timer.doAfter(fadeTime, function() canvas:delete() end)
    end
end

-- === Bind Hotkey ===
function obj:bindHotkey()
    hs.hotkey.bind(self.hotkey.mods, self.hotkey.key, function()
        self:showWindowChooser()
    end)
end

return obj
