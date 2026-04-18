local M = {}
local initialized = false

local PATCH_MODULES = {
    night_mode_schedule    = "modules/global/patches/night_mode_schedule",
    warmth_schedule        = "modules/global/patches/warmth_schedule",
    brightness_schedule    = "modules/global/patches/brightness_schedule",
    disable_night_on_exit  = "modules/global/patches/disable_night_on_exit",
    menu_top_swipe         = "modules/global/patches/menu_top_swipe",
}

local function run_patch(logger, plugin, feature, fn)
    local prev_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    _G.__ZEN_UI_PLUGIN = plugin
    local ok, err = pcall(fn)
    _G.__ZEN_UI_PLUGIN = prev_plugin
    if not ok and logger then
        logger.warn("zen-ui: global patch failed", feature, err)
    end
    return ok
end

local function load_patch(feature)
    local module_name = PATCH_MODULES[feature]
    if not module_name then return nil end
    local ok, patch_fn = pcall(require, module_name)
    if not ok or type(patch_fn) ~= "function" then return nil end
    return patch_fn
end

function M.init(logger, plugin)
    if initialized then return true end

    -- Always apply: night-mode scheduler (self-disables when feature is off).
    local night_mode_schedule_fn = load_patch("night_mode_schedule")
    if night_mode_schedule_fn then
        run_patch(logger, plugin, "night_mode_schedule", night_mode_schedule_fn)
    end

    -- Always apply: warmth scheduler (no-ops on devices without natural light).
    local warmth_schedule_fn = load_patch("warmth_schedule")
    if warmth_schedule_fn then
        run_patch(logger, plugin, "warmth_schedule", warmth_schedule_fn)
    end

    -- Always apply: brightness scheduler.
    local brightness_schedule_fn = load_patch("brightness_schedule")
    if brightness_schedule_fn then
        run_patch(logger, plugin, "brightness_schedule", brightness_schedule_fn)
    end

    -- Always apply: disable night mode on Exit/Restart from any menu.
    local disable_night_on_exit_fn = load_patch("disable_night_on_exit")
    if disable_night_on_exit_fn then
        run_patch(logger, plugin, "disable_night_on_exit", disable_night_on_exit_fn)
    end

    -- Always apply: top-14% south swipe opens KOReader menu from any Menu view.
    local menu_top_swipe_fn = load_patch("menu_top_swipe")
    if menu_top_swipe_fn then
        run_patch(logger, plugin, "menu_top_swipe", menu_top_swipe_fn)
    end

    -- -----------------------------------------------------------------
    -- Device-level power hooks (bypass widget event tree).
    --
    -- The widget-level onResume/onSuspend hooks installed by the schedule
    -- modules rely on KOReader dispatching Resume/Suspend events through
    -- the entire widget tree down to our plugin.  This can fail if any
    -- widget earlier in the tree consumes the event.  To guarantee the
    -- schedules are always (re-)applied on wake, we also hook directly
    -- into Device._afterResume / Device._beforeSuspend, which run on
    -- every power transition regardless of the widget stack.
    -- -----------------------------------------------------------------
    local Device = require("device")
    local SCHEDULE_STATES = {
        "__ZEN_UI_NIGHT_SCHEDULE",
        "__ZEN_UI_BRIGHTNESS_SCHEDULE",
        "__ZEN_UI_WARMTH_SCHEDULE",
    }

    if type(Device._afterResume) == "function" then
        local orig_afterResume = Device._afterResume
        Device._afterResume = function(self, ...)
            local result = orig_afterResume(self, ...)
            for _, name in ipairs(SCHEDULE_STATES) do
                local state = rawget(_G, name)
                if type(state) == "table" then
                    local fn = state.force_reschedule or state.reschedule
                    if type(fn) == "function" then pcall(fn) end
                end
            end
            return result
        end
    end

    if type(Device._beforeSuspend) == "function" then
        local orig_beforeSuspend = Device._beforeSuspend
        Device._beforeSuspend = function(self, ...)
            for _, name in ipairs(SCHEDULE_STATES) do
                local state = rawget(_G, name)
                if type(state) == "table" and type(state._on_suspend) == "function" then
                    pcall(state._on_suspend)
                end
            end
            return orig_beforeSuspend(self, ...)
        end
    end

    initialized = true
    return true
end

return M
