-- Zen UI: Icon-only DictQuickLookup buttons
-- Replaces the dictionary popup's text button row with a compact icon row.
-- Hooks via DictButtonsReady event on ReaderHighlight (fired by DictQuickLookup).
-- When "show other items" is enabled, unknown buttons are preserved as a text row.

local function apply()
    local ReaderHighlight = require("apps/reader/modules/readerhighlight")
    local Translator = require("ui/translator")
    local logger = require("logger")

    local _plugin_ref = rawget(_G, "__ZEN_UI_PLUGIN")

    local function is_enabled()
        local features = _plugin_ref
            and _plugin_ref.config
            and _plugin_ref.config.features
        return type(features) == "table" and features.dict_quick_lookup == true
    end

    local function show_wikipedia()
        local cfg = _plugin_ref
            and _plugin_ref.config
            and _plugin_ref.config.highlight_lookup
        return type(cfg) == "table" and cfg.show_wikipedia == true
    end

    local function allow_unknown()
        local cfg = _plugin_ref
            and _plugin_ref.config
            and _plugin_ref.config.highlight_lookup
        return type(cfg) == "table" and cfg.allow_unknown_items == true
    end

    -- IDs we handle explicitly; everything else is "unknown".
    local KNOWN_IDS = {
        highlight = true, search = true, wikipedia = true,
        translate = true, close = true,
        vocabulary = true, prev_dict = true, next_dict = true,
    }

    -- Build a minimal icon-only spec from an original button.
    local function icon_btn(orig, icon)
        if not orig then return nil end
        return {
            id            = orig.id,
            icon          = icon,
            enabled       = orig.enabled,
            enabled_func  = orig.enabled_func,
            callback      = orig.callback,
            hold_callback = orig.hold_callback,
        }
    end

    -- Called by DictQuickLookup just before it builds its ButtonTable.
    -- Mutates `buttons` in-place to replace rows with a single icon row.
    ReaderHighlight.onDictButtonsReady = function(self, dict_widget, buttons)
        logger.dbg("zen-ui[dict_quick_lookup]: onDictButtonsReady, is_enabled=",
            tostring(is_enabled()), "is_wiki=", tostring(dict_widget.is_wiki),
            "is_wiki_fullpage=", tostring(dict_widget.is_wiki_fullpage))
        if not is_enabled() then return end
        if dict_widget.is_wiki or dict_widget.is_wiki_fullpage then return end

        local by_id = {}
        local unknown = {}
        for _, row in ipairs(buttons) do
            for _, btn in ipairs(row) do
                if btn.id then
                    if KNOWN_IDS[btn.id] then
                        by_id[btn.id] = btn
                    else
                        table.insert(unknown, btn)
                    end
                end
            end
        end

        -- Translate is not included in the DictButtonsReady event; build manually.
        local translate_btn = {
            id   = "translate",
            icon = "lookup.translate",
            callback = function()
                Translator:showTranslation(dict_widget.word, true)
            end,
        }

        local icon_row = {}
        local h = icon_btn(by_id["highlight"], "lookup.highlight")
        local w = show_wikipedia() and icon_btn(by_id["wikipedia"], "lookup.wikipedia") or nil
        local s = icon_btn(by_id["search"],    "lookup.search")
        if h then table.insert(icon_row, h) end
        if w then table.insert(icon_row, w) end
        table.insert(icon_row, translate_btn)
        if s then table.insert(icon_row, s) end

        if #icon_row == 0 then
            logger.dbg("zen-ui[dict_quick_lookup]: no known button ids found, leaving unchanged")
            return
        end

        -- Replace the entire buttons table in-place.
        for i = #buttons, 1, -1 do table.remove(buttons, i) end
        table.insert(buttons, icon_row)

        -- Preserve unknown buttons as a plain text row when enabled.
        if allow_unknown() and #unknown > 0 then
            table.insert(buttons, unknown)
        end

        logger.dbg("zen-ui[dict_quick_lookup]: replaced buttons, icon_row=",
            #icon_row, "unknown=", #unknown)
    end

    logger.dbg("zen-ui[dict_quick_lookup]: onDictButtonsReady handler installed")
end

return apply
