-- zen_ui: sync_night_mode patch
-- Two-way sync between KOReader's night_mode state and the actual HW display.
--
-- 1. STARTUP SYNC
--    KOReader's Device:init() (generic/device.lua) reads G_reader_settings
--    and calls toggleNightMode() only when night_mode == true.  It does NOT
--    call setHWNightmode(false) when night_mode == false, so if the Kindle OS
--    had dark mode active before launch the EPDC inversion flag stays set.
--    Result: screen looks inverted, KOReader's night-mode toggle shows OFF.
--
--    Three cases when EPDC is inverted but Screen.night_mode is false:
--      a) saved == true  → Device:init already called toggleNightMode();
--                          Screen.night_mode is already true; guard never fires.
--      b) saved == false → user explicitly chose light mode in KOReader.
--                          Call setHWNightmode(false) to override OS dark mode.
--                          Do NOT change Screen.night_mode or the saved setting.
--      c) saved == nil   → first launch / no prior preference.
--                          Adopt the OS state: sync flag + saved setting.
--
-- 2. EXIT GUARD
--    Before Exit or Restart, if night mode is active, disable it so the
--    Kindle OS doesn't inherit an inverted framebuffer.
--    For HW-invert devices (Kindle EPDC), toggleNightMode() is a synchronous
--    driver write — no repaint or deferred scheduling needed.
--    For SW-invert devices, force a full repaint to un-invert the pixel data.
--    NOTE: Do NOT defer the exit via scheduleIn(); UIManager:quit() wipes the
--    task queue, so deferred retriggers are silently lost.

local function apply_disable_night_on_exit()

    local UIManager = require("ui/uimanager")
    local Device    = require("device")
    local Screen    = Device.screen

    if rawget(_G, "__ZEN_UI_NIGHT_EXIT_PATCHED") then return end
    _G.__ZEN_UI_NIGHT_EXIT_PATCHED = true

    -- -----------------------------------------------------------------------
    -- 1. STARTUP SYNC
    -- -----------------------------------------------------------------------
    local hw_inverted = false
    if type(Screen.getHWNightmode) == "function" then
        pcall(function() hw_inverted = Screen:getHWNightmode() end)
    end

    if hw_inverted and not Screen.night_mode then
        -- EPDC is inverted (Kindle OS dark mode) but KOReader flag says false.
        local saved_night = G_reader_settings:readSetting("night_mode")
        if saved_night == false then
            -- User explicitly saved light mode (exact Lua false, not nil).
            -- Override the OS dark mode: force EPDC inversion off.
            -- setHWNightmode() writes the EPDC flag directly without touching
            -- Screen.night_mode, which is already correct (false).
            -- Note: Device:exit() will restore orig_hw_nightmode (true) on
            -- exit, so EPDC gets re-set by KOReader's own cleanup.  We simply
            -- re-apply this fix on each startup — that is acceptable.
            if type(Screen.setHWNightmode) == "function" then
                pcall(function() Screen:setHWNightmode(false) end)
            end
            UIManager:setDirty("all", "full")
        else
            -- saved_night is nil (no prior preference) or true (already dark).
            -- Adopt the OS/HW dark mode: sync KOReader's flag and saved setting.
            -- Do NOT call toggleNightMode() — HW is already in the correct state.
            Screen.night_mode = true
            pcall(function() UIManager:ToggleNightMode(true) end)
            G_reader_settings:saveSetting("night_mode", true)
            UIManager:setDirty("all", "full")
        end
    end

    -- -----------------------------------------------------------------------
    -- 2. EXIT GUARD
    -- -----------------------------------------------------------------------
    local orig_broadcastEvent = UIManager.broadcastEvent
    UIManager.broadcastEvent = function(self, event, ...)
        if event and (event.name == "Exit" or event.name == "Restart") then
            if Screen.night_mode then
                -- toggleNightMode() flips the flag and either clears the HW
                -- EPDC invert flag (canHWInvert) or inverts the SW blitbuffer.
                Screen:toggleNightMode()
                pcall(function() UIManager:ToggleNightMode(false) end)
                G_reader_settings:saveSetting("night_mode", false)
                -- For SW-invert devices: flush the now-un-inverted blitbuffer
                -- to the display before shutdown.
                if not Device:canHWInvert() then
                    UIManager:setDirty("all", "full")
                    pcall(function() UIManager:forceRePaint() end)
                end
            end
        end
        return orig_broadcastEvent(self, event, ...)
    end

end

return apply_disable_night_on_exit

