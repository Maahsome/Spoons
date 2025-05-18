local obj = {}
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
--- With this Spoon you will be able to target a specific application (Google Chrome, iTerm2, Sublime Text) and assign a hyper key to cascade the open windows.
--- Official homepage for more info and documentation:
--- [https://github.com/cmaahs/app-window-switcher-spoon](https://github.com/cmaahs/app-window-switcher-spoon)
---

obj.__index = obj

-- Metadata
obj.name = "AppWindowSwitcher"
obj.version = "1.0"
obj.author = "Christopher Maahs <cmaahs@gmail.com>"
obj.license = "MIT"

obj.hotkey = { mods = {"command", "cmd", "alt"}, key = "w" }
obj._chooser = nil

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
    local appIcon = hs.image.imageFromAppBundle(app:bundleID())

    local windows = hs.fnutils.filter(app:allWindows(), function(win)
        return win:isVisible()
    end)

    table.sort(windows, function(a, b)
        return a:title():lower() < b:title():lower()
    end)

    if #windows == 0 then
        hs.alert.show("No visible windows found")
        return
    end

    local choices = hs.fnutils.imap(windows, function(win)
        return {
            text = win:title(),
            subText = appName,
            uuid = win:id(),
            image = appIcon
        }
    end)

    self._chooser = hs.chooser.new(function(choice)
        if not choice then return end
        for _, win in ipairs(windows) do
            if win:id() == choice.uuid then
                win:focus()
                break
            end
        end
    end)

    self._chooser:choices(choices)
    self._chooser:show()
end

function obj:bindHotkey()
    hs.hotkey.bind(self.hotkey.mods, self.hotkey.key, function()
        self:showWindowChooser()
    end)
end

return obj
