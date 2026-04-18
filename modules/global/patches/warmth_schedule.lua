local function apply_warmth_schedule()
    --[[
        Automatically sets screen warmth at two user-defined times each day.
        Only active on devices with a natural-light (warm/cool) frontlight.

        Uses UIManager:scheduleIn / unschedule with stable function references,
        matching the same pattern as night_mode_schedule.lua.  On every resume
        the correct warmth is applied immediately (in case the transition
        happened during sleep), then both timers are re-armed from now.

        Public reschedule() is exposed via __ZEN_UI_WARMTH_SCHEDULE so that
        settings callbacks can trigger an immediate re-apply on config changes.

        Note: Device:hasNaturalLight() is checked at call-time inside set_warmth
        rather than at init time, because on some devices the warm-light hardware
        is not yet fully initialised when the plugin loads.
    --]]

    local Device = require("device")
    local UIManager = require("ui/uimanager")

    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    if not zen_plugin or type(zen_plugin.config) ~= "table" then return end

    local state = rawget(_G, "__ZEN_UI_WARMTH_SCHEDULE")
    if type(state) ~= "table" then
        state = {}
        _G.__ZEN_UI_WARMTH_SCHEDULE = state
    end

    if state.initialized then return end

    -- -------------------------------------------------------------------------
    -- Helpers
    -- -------------------------------------------------------------------------

    local function is_enabled()
        local plugin   = zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
        local features = plugin and plugin.config and plugin.config.features
        return type(features) == "table" and features.warmth_schedule == true
    end

    local function get_config()
        local plugin = zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
        local cfg    = plugin and plugin.config and plugin.config.warmth_schedule
        if type(cfg) ~= "table" then cfg = {} end
        return {
            day_h       = tonumber(cfg.day_h)       or 7,
            day_m       = tonumber(cfg.day_m)       or 0,
            day_value   = tonumber(cfg.day_value)   or 30,
            night_h     = tonumber(cfg.night_h)     or 20,
            night_m     = tonumber(cfg.night_m)     or 0,
            night_value = tonumber(cfg.night_value) or 80,
        }
    end

    local function now_s()
        local t = os.date("*t")
        return t.hour * 3600 + t.min * 60 + t.sec
    end

    local function seconds_until(h, m)
        local diff = (h * 3600 + m * 60) - now_s()
        if diff <= 0 then diff = diff + 86400 end
        return diff
    end

    -- Returns the warmth value that should be active right now.
    local function current_warmth_value()
        local cfg   = get_config()
        local cur   = now_s()
        local day_s   = cfg.day_h   * 3600 + cfg.day_m   * 60
        local night_s = cfg.night_h * 3600 + cfg.night_m * 60
        if day_s == night_s then return cfg.day_value end
        if day_s < night_s then
            return (cur >= day_s and cur < night_s) and cfg.day_value or cfg.night_value
        else
            -- Day window wraps midnight
            return (cur >= day_s or cur < night_s) and cfg.day_value or cfg.night_value
        end
    end

    local function set_warmth(value)
        local Powerd = Device.powerd
        if Powerd and type(Powerd.setWarmth) == "function" then
            -- setWarmth expects an internal 0-100 range; our config stores 0-24.
            local scaled = math.floor(value * 100 / 24 + 0.5)
            pcall(Powerd.setWarmth, Powerd, math.max(0, math.min(100, scaled)))
            UIManager:setDirty("all", "ui")
        end
    end

    -- -------------------------------------------------------------------------
    -- Stable function references required by UIManager:unschedule
    -- -------------------------------------------------------------------------

    local day_fn
    local night_fn

    day_fn = function()
        if is_enabled() then
            set_warmth(get_config().day_value)
            UIManager:scheduleIn(86400, day_fn)
        end
    end

    night_fn = function()
        if is_enabled() then
            set_warmth(get_config().night_value)
            UIManager:scheduleIn(86400, night_fn)
        end
    end

    -- -------------------------------------------------------------------------
    -- Public reschedule
    -- -------------------------------------------------------------------------

    local function reschedule()
        UIManager:unschedule(day_fn)
        UIManager:unschedule(night_fn)
        if not is_enabled() then return end
        set_warmth(current_warmth_value())
        local cfg = get_config()
        UIManager:scheduleIn(seconds_until(cfg.day_h,   cfg.day_m),   day_fn)
        UIManager:scheduleIn(seconds_until(cfg.night_h, cfg.night_m), night_fn)
    end

    state.reschedule  = reschedule
    state.initialized = true

    -- -------------------------------------------------------------------------
    -- Suspend / resume hooks – chain onto any previously installed hooks
    -- -------------------------------------------------------------------------

    local orig_suspend = zen_plugin.onSuspend
    zen_plugin.onSuspend = function(self, ...)
        UIManager:unschedule(day_fn)
        UIManager:unschedule(night_fn)
        if type(orig_suspend) == "function" then
            return orig_suspend(self, ...)
        end
    end

    local orig_resume = zen_plugin.onResume
    zen_plugin.onResume = function(self, ...)
        local result
        if type(orig_resume) == "function" then
            result = orig_resume(self, ...)
        end
        reschedule()
        return result
    end

    -- -------------------------------------------------------------------------
    -- Boot-time: apply correct state and arm timers
    -- -------------------------------------------------------------------------

    if is_enabled() then
        reschedule()
    end
end

return apply_warmth_schedule
