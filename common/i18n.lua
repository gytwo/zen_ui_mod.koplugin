-- common/i18n.lua — Zen UI
-- Loads the plugin's own .po translation for the current KOReader language
-- and wraps package.loaded["gettext"] so all subsequent require("gettext")
-- calls in every plugin module receive the override automatically.
--
-- USAGE: call i18n.install() as the FIRST statement in main.lua, before any
-- other require().  Call i18n.uninstall() in ZenUI:onCloseWidget / teardown.

local logger = require("logger")

local _dir = (debug.getinfo(1, "S").source:match("^@(.+/)") or "./")

-- ---------------------------------------------------------------------------
-- Minimal .po parser — handles msgctxt, msgid, msgstr, multiline continuations
-- ---------------------------------------------------------------------------
local function parsePO(path)
    local f = io.open(path, "r")
    if not f then return nil end

    local translations = {}  -- [msgid] = msgstr
    local contexts     = {}  -- [msgctxt][msgid] = msgstr

    local ctx, id, str
    local in_id, in_str, in_ctx = false, false, false

    local function unescape(s)
        return s:gsub("\\n", "\n")
                :gsub("\\t", "\t")
                :gsub('\\"', '"')
                :gsub("\\\\", "\\")
    end

    local function flush()
        if id and id ~= "" and str and str ~= "" then
            if ctx and ctx ~= "" then
                if not contexts[ctx] then contexts[ctx] = {} end
                contexts[ctx][id] = str
            else
                translations[id] = str
            end
        end
        ctx, id, str = nil, nil, nil
        in_id, in_str, in_ctx = false, false, false
    end

    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line == "" or line:match("^#") then
            if line == "" then flush() end
        elseif line:match("^msgctxt%s+\"") then
            flush()
            ctx   = unescape(line:match('^msgctxt%s+"(.*)"') or "")
            in_ctx = true; in_id = false; in_str = false
        elseif line:match("^msgid%s+\"") then
            -- don't flush here if we just saw msgctxt; they belong together
            if not in_ctx then flush() end
            in_ctx = false
            id    = unescape(line:match('^msgid%s+"(.*)"') or "")
            in_id = true; in_str = false
        elseif line:match("^msgstr%s+\"") then
            str    = unescape(line:match('^msgstr%s+"(.*)"') or "")
            in_str = true; in_id = false; in_ctx = false
        elseif line:match('^"') then
            local cont = unescape(line:match('^"(.*)"') or "")
            if in_ctx and ctx  then ctx = ctx .. cont end
            if in_id  and id   then id  = id  .. cont end
            if in_str and str  then str = str .. cont end
        end
    end
    flush()
    f:close()

    local count = 0
    for _ in pairs(translations) do count = count + 1 end
    for _ in pairs(contexts)     do count = count + 1 end

    return translations, contexts, count
end

-- ---------------------------------------------------------------------------
-- Language detection — mirrors KOReader's own priority order
-- ---------------------------------------------------------------------------
local function detectLang()
    local lang = G_reader_settings and G_reader_settings:readSetting("language")
    if type(lang) == "string" and lang ~= "" then return lang end
    local lc = os.getenv("LANG") or os.getenv("LC_ALL") or os.getenv("LC_MESSAGES") or ""
    lang = lc:match("^([a-zA-Z_]+)")
    return lang or "en"
end

-- ---------------------------------------------------------------------------
-- Load the best-matching .po file for the current language
-- ---------------------------------------------------------------------------
local function loadTranslations()
    local lang = detectLang()
    if lang == "en" or lang:match("^en_") then return nil, nil end

    local function try(name)
        local path = _dir .. "../locales/" .. name .. ".po"
        local t, c, n = parsePO(path)
        if t and n and n > 0 then
            logger.info("zen-ui i18n: loaded " .. path .. " — " .. n .. " entries")
            return t, c
        end
    end

    local t, c = try(lang)
    if t then return t, c end

    -- fallback: try language prefix only (e.g. "pt" for "pt_BR")
    local prefix = lang:match("^([a-zA-Z]+)")
    if prefix and prefix ~= lang then
        return try(prefix)
    end
end

-- ---------------------------------------------------------------------------
-- install / uninstall
-- ---------------------------------------------------------------------------
local _installed    = false
local _orig_gettext = nil

local function install()
    if _installed then return end

    local translations, contexts = loadTranslations()
    if not translations then return end  -- English or unsupported language

    -- Ensure gettext is in package.loaded before we wrap it
    local orig = package.loaded["gettext"]
    if not orig then
        local ok, gt = pcall(require, "gettext")
        if not ok or not gt then
            logger.warn("zen-ui i18n: cannot load gettext — translations disabled")
            return
        end
        orig = gt
    end
    _orig_gettext = orig

    local wrapper
    local mt = getmetatable(orig)
    if mt and mt.__call then
        -- gettext is a callable table (the normal KOReader case)
        wrapper = setmetatable({}, {
            __call = function(_, msgid)
                local t = translations[msgid]
                if t then return t end
                return orig(msgid)
            end,
            __index = function(_, key)
                -- pgettext: function(msgctxt, msgid)
                if key == "pgettext" then
                    return function(msgctxt, msgid)
                        local t = contexts[msgctxt] and contexts[msgctxt][msgid]
                        if t then return t end
                        return orig.pgettext(msgctxt, msgid)
                    end
                end
                -- ngettext, npgettext, etc. — delegate to original
                return orig[key]
            end,
        })
    elseif type(orig) == "function" then
        wrapper = function(msgid)
            local t = translations[msgid]
            if t then return t end
            return orig(msgid)
        end
    else
        logger.warn("zen-ui i18n: unexpected gettext type: " .. type(orig))
        return
    end

    package.loaded["gettext"] = wrapper
    _installed = true
    logger.info("zen-ui i18n: installed wrapper for lang=" .. detectLang())
end

local function uninstall()
    if not _installed then return end
    package.loaded["gettext"] = _orig_gettext
    _orig_gettext = nil
    _installed    = false
    logger.info("zen-ui i18n: uninstalled")
end

return {
    install   = install,
    uninstall = uninstall,
    getLang   = detectLang,
}
