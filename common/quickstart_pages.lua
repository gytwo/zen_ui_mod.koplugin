-- Quickstart slideshow page definitions.
-- INSTALL_PAGES: shown on first install.
-- UPDATE_PAGES: keyed by version string; add a table for each release that
--   has noteworthy changes. Omit a key to silently skip the screen for that
--   release.
-- Each page: { title = string, image = string|nil, description = string }

local M = {}

local _plugin_root = (function()
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) ~= "@" then return "" end
    return src:sub(2):match("^(.*)/common/[^/]+%.lua$") or ""
end)()

local function img(rel)
    return _plugin_root .. "/images/quickstart/" .. rel
end

M.INSTALL_PAGES = {
    {
        title       = "Welcome to Zen UI",
        icon        = "zen_ui",
        description = "A minimal, beautiful interface for your e-reader.\n\nSwipe or tap Next to continue.",
    },
    {
        title       = "Zen Mode",
        image       = img("onboarding/zen_mode.svg"),
        description = "Strip KOReader down to its bare essentials.\nRemoves visual clutter for a focused, distraction-free reading experience.",
    },
    {
        title       = "Navigation Bar",
        image       = img("onboarding/navbar.svg"),
        description = "A clean, tab-based bar at the bottom of your library.\nConfigurable tabs: Books, Favorites, History, Collections, and more.",
    },
    {
        title       = "Quick Settings",
        image       = img("onboarding/quick_settings.svg"),
        description = "Swipe down to reach frontlight, warmth, Wi-Fi, night mode, and more.\nFully configurable — reorder or hide any button.",
    },
    {
        title       = "Status Bars",
        image       = img("onboarding/status_bars.svg"),
        description = "Minimal status bars in the reader and library.\nShow only what you need: time, battery, progress, and more.",
    },
    {
        title       = "File Browser",
        image       = img("onboarding/file_browser.svg"),
        description = "Cover images as folder thumbnails, clean mosaic and list views,\nhidden clutter, and a streamlined context menu.",
    },
    {
        title       = "Reader",
        image       = img("onboarding/reader.svg"),
        description = "An unobtrusive clock overlay, disabled accidental bottom menu,\nand clean footer presets for the reading view.",
    },
    {
        title       = "Settings & Updates",
        image       = img("onboarding/settings.svg"),
        description = "All settings in one unified tab.\nCheck for and install Zen UI updates directly from your e-reader.",
    },
}

M.UPDATE_PAGES = {
    -- Add per-version pages when releasing updates. Example:
    -- ["0.1.0"] = {
    --     { title = "What's New in 0.1.0", image = img("0.1.0/feature.png"), description = "..." },
    -- },
}

return M
