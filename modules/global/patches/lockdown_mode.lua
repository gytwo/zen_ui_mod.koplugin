local function apply_lockdown_mode()
    -- Lockdown mode: restricts context menu, page browser, and reader hold gestures.
    -- Wraps are layered on top of margin_hold_guard (which runs in reader module,
    -- before global). Chain: lockdown -> margin_hold_guard -> original.

    local _plugin_ref = rawget(_G, "__ZEN_UI_PLUGIN")
    if not _plugin_ref or type(_plugin_ref.config) ~= "table" then return end

    local function is_lockdown()
        local features = _plugin_ref.config.features
        return type(features) == "table" and features.lockdown_mode == true
    end

    local function lockdown_cfg()
        local c = _plugin_ref.config.lockdown
        return type(c) == "table" and c or {}
    end

    -- -----------------------------------------------------------------------
    -- Reader hold / selection guards
    -- -----------------------------------------------------------------------

    local ok_rh, ReaderHighlight = pcall(require, "apps/reader/modules/readerhighlight")
    if not ok_rh or not ReaderHighlight then return end

    -- Guard: swallow the entire hold gesture (no word highlight, no popup).
    local _orig_onHold = ReaderHighlight.onHold
    ReaderHighlight.onHold = function(self, arg, ges)
        if is_lockdown() and lockdown_cfg().disable_hold_search then
            return false
        end
        return _orig_onHold(self, arg, ges)
    end

    -- Guard: swallow hold-pan (prevents extending a selection to multiple words).
    local _orig_onHoldPan = ReaderHighlight.onHoldPan
    if _orig_onHoldPan then
        ReaderHighlight.onHoldPan = function(self, arg, ges)
            if is_lockdown() and lockdown_cfg().disable_word_selection then
                return false
            end
            return _orig_onHoldPan(self, arg, ges)
        end
    end
end

return apply_lockdown_mode
