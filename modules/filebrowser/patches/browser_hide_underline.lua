local function apply_browser_hide_underline()
    local Blitbuffer = require("ffi/blitbuffer")
    local _ = require("gettext")

    local function getMenuItem(menu, ...)
        local function findItem(sub_items, texts)
            local find = {}
            local texts = type(texts) == "table" and texts or { texts }
            for _, text in ipairs(texts) do
                find[text] = true
            end
            for _, item in ipairs(sub_items) do
                local text = item.text or (item.text_func and item.text_func())
                if text and find[text] then
                    return item
                end
            end
        end

        local sub_items, item
        for _, texts in ipairs { ... } do
            sub_items = (item or menu).sub_item_table
            if not sub_items then
                return
            end
            item = findItem(sub_items, texts)
            if not item then
                return
            end
        end
        return item
    end

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
        local MosaicMenu = require("mosaicmenu")
        local MosaicMenuItem = get_upvalue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
        if not MosaicMenuItem then
            return
        end
        local BookInfoManager = get_upvalue(MosaicMenuItem.update, "BookInfoManager")

        function BooleanSetting(text, name, default)
            self = { text = text }
            self.get = function()
                local setting = BookInfoManager:getSetting(name)
                if default then
                    return not setting
                end
                return setting
            end
            self.toggle = function()
                return BookInfoManager:toggleSetting(name)
            end
            return self
        end

        local settings = {
            hide_underline = BooleanSetting(_("Hide last visited underline"), "folder_hide_underline", true),
        }

        function MosaicMenuItem:onFocus()
            self._underline_container.color = settings.hide_underline.get() and Blitbuffer.COLOR_WHITE
                or Blitbuffer.COLOR_BLACK
            return true
        end

        local orig_CoverBrowser_addToMainMenu = plugin.addToMainMenu

        function plugin:addToMainMenu(menu_items)
            orig_CoverBrowser_addToMainMenu(self, menu_items)
            if menu_items.filebrowser_settings == nil then
                return
            end

            local item = getMenuItem(menu_items.filebrowser_settings, _("Mosaic and detailed list settings"))
            if item then
                item.sub_item_table[#item.sub_item_table].separator = true
                for _, setting in pairs(settings) do
                    if not getMenuItem(
                        menu_items.filebrowser_settings,
                        _("Mosaic and detailed list settings"),
                        setting.text
                    ) then
                        table.insert(item.sub_item_table, {
                            text = setting.text,
                            checked_func = function()
                                return setting.get()
                            end,
                            callback = function()
                                setting.toggle()
                            end,
                        })
                    end
                end
            end
        end
    end

    local ok, coverbrowser = pcall(require, "coverbrowser")
    if ok and coverbrowser then
        patchCoverBrowser(coverbrowser)
    end
end


return apply_browser_hide_underline
