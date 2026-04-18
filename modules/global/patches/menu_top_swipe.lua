-- Global patch: south swipe handling for all Menu-based views.
--
-- Top 14%  → opens the KOReader menu (FileManager or Reader, whichever is active).
-- Elsewhere → swallowed so views are never accidentally closed.
--
-- Patched once at the *class* level so every Menu instance inherits the
-- behaviour automatically — no per-view wiring required.
local function apply_menu_top_swipe()
    local Device = require("device")
    local Menu   = require("ui/widget/menu")

    local orig_onSwipe = Menu.onSwipe

    Menu.onSwipe = function(self, arg, ges_ev)
        if ges_ev.direction == "south" then
            if ges_ev.pos.y < Device.screen:getHeight() * 0.14 then
                -- Try FileManager menu first (library / filebrowser context)
                local fm = require("apps/filemanager/filemanager").instance
                if fm and fm.menu then
                    local fm_menu = fm.menu
                    if fm_menu.activation_menu ~= "tap" then
                        fm_menu:onShowMenu(fm_menu:_getTabIndexFromLocation(ges_ev))
                        return true
                    end
                end
                -- Fall back to Reader menu (bookmarks, etc.)
                local ok_rui, RUI = pcall(require, "apps/reader/readerui")
                if ok_rui and RUI and RUI.instance then
                    local reader_menu = RUI.instance.menu
                    if reader_menu and reader_menu.activation_menu ~= "tap" then
                        reader_menu:onShowMenu(reader_menu:_getTabIndexFromLocation(ges_ev))
                        return true
                    end
                end
            end
            -- Swallow all other south swipes so views are never closed by accident.
            return true
        end
        return orig_onSwipe(self, arg, ges_ev)
    end
end

return apply_menu_top_swipe
