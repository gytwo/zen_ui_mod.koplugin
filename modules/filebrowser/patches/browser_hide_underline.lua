local function apply_browser_hide_underline()
    local Blitbuffer = require("ffi/blitbuffer")

    local function get_upvalue(fn, name)
        if type(fn) ~= "function" then
            return nil
        end
        for i = 1, 64 do
            local upname, value = debug.getupvalue(fn, i)
            if not upname then
                break
            end
            if upname == name then
                return value
            end
        end
    end

    local function patchCoverBrowser(plugin)
        -- Patch MosaicMenuItem (mosaic display modes)
        local MosaicMenu = require("mosaicmenu")
        local MosaicMenuItem = get_upvalue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
        if MosaicMenuItem and not MosaicMenuItem._zen_hide_underline_patched then
            MosaicMenuItem._zen_hide_underline_patched = true

            local BookInfoManager = get_upvalue(MosaicMenuItem.update, "BookInfoManager")
            if BookInfoManager and BookInfoManager.getSetting and BookInfoManager.toggleSetting then
                local setting = BookInfoManager:getSetting("folder_hide_underline")
                if setting == true then
                    BookInfoManager:toggleSetting("folder_hide_underline")
                end
            end

            local orig_mosaic_update = MosaicMenuItem.update
            function MosaicMenuItem:update(...)
                orig_mosaic_update(self, ...)
                if self._underline_container then
                    self._underline_container.color = Blitbuffer.COLOR_WHITE
                end
            end

            function MosaicMenuItem:onFocus()
                if self._underline_container then
                    self._underline_container.color = Blitbuffer.COLOR_WHITE
                end
                return true
            end
        end

        -- Patch ListMenuItem (list display modes)
        local ok_lm, ListMenu = pcall(require, "listmenu")
        if ok_lm then
            local ListMenuItem = get_upvalue(ListMenu._updateItemsBuildUI, "ListMenuItem")
            if ListMenuItem and not ListMenuItem._zen_hide_underline_patched then
                ListMenuItem._zen_hide_underline_patched = true

                local orig_list_update = ListMenuItem.update
                function ListMenuItem:update(...)
                    orig_list_update(self, ...)
                    if self._underline_container then
                        self._underline_container.color = Blitbuffer.COLOR_WHITE
                    end
                end

                function ListMenuItem:onFocus()
                    if self._underline_container then
                        self._underline_container.color = Blitbuffer.COLOR_WHITE
                    end
                    return true
                end
            end
        end
    end

    -- Export shared utilities for other patches (e.g. collections classic mode)
    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    if zen_plugin then
        if not zen_plugin._zen_shared then zen_plugin._zen_shared = {} end
        zen_plugin._zen_shared.hide_underline_active = true
        zen_plugin._zen_shared.patchMenuHideUnderline = function(menu)
            local Menu_class = require("ui/widget/menu")
            local base_updateItems = menu.updateItems or Menu_class.updateItems
            menu.updateItems = function(self_m, ...)
                base_updateItems(self_m, ...)
                if self_m.item_group then
                    for _, w in ipairs(self_m.item_group) do
                        if w._underline_container then
                            w._underline_container.color = Blitbuffer.COLOR_WHITE
                        end
                    end
                end
            end
        end
    end

    -- Primary path: register with userpatch so coverbrowser patch timing is correct.
    local ok_userpatch, userpatch = pcall(require, "userpatch")
    if ok_userpatch and userpatch and type(userpatch.registerPatchPluginFunc) == "function" then
        userpatch.registerPatchPluginFunc("coverbrowser", patchCoverBrowser)
    else
        -- Fallback for environments without userpatch.
        local ok_coverbrowser, coverbrowser = pcall(require, "coverbrowser")
        if ok_coverbrowser and coverbrowser then
            patchCoverBrowser(coverbrowser)
        end
    end
end

return apply_browser_hide_underline
