-- Add to ~/.hammerspoon/init.lua

hs.loadSpoon("ContextStack")

-- Optional tweaks (defaults shown):
-- spoon.ContextStack.maxEntries = 7
-- spoon.ContextStack.captureDir = os.getenv("HOME") .. "/ContextStack"
-- spoon.ContextStack.autoPaste = true    -- false: don't Cmd+V automatically after capture

spoon.ContextStack:start()
spoon.ContextStack:bindHotkeys({ show = { { "ctrl", "alt" }, "space" } })
