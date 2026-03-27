local function apply_hide_pagination()
    -- Hide pagination bar in KOReader File Manager
    -- Removes the "« < Page 1 of 2 > »" footer from the file browser,
    -- history, favorites, and collections views.
    -- Swipe gestures for page navigation still work.

    local Menu = require("ui/widget/menu")
    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")

    local function is_enabled()
        local features = zen_plugin and zen_plugin.config and zen_plugin.config.features
        return type(features) == "table" and features.hide_pagination == true
    end

    local hide_pagination_names = {
        filemanager = true,
        history = true,
        collections = true,
    }

    local orig_menu_init = Menu.init

    function Menu:init()
        orig_menu_init(self)

        if not is_enabled() then
            return
        end

        -- Match by name, or by full-screen fm-style menus (e.g. collections list has no name)
        if not hide_pagination_names[self.name]
           and not (self.covers_fullscreen and self.is_borderless and self.title_bar_fm_style) then
            return
        end

        -- self[1] is FrameContainer, self[1][1] is the content OverlapGroup
        local content = self[1] and self[1][1]
        if not content then return end

        -- The OverlapGroup contains: content_group, page_return, footer
        -- Remove page_return and footer but keep content_group
        for i = #content, 1, -1 do
            if content[i] ~= self.content_group then
                table.remove(content, i)
            end
        end

        -- Recalculate to fill the space freed by removing the footer.
        -- We can't nil page_info_text/page_return_arrow since updatePageInfo
        -- still calls methods on them. Instead, override _recalculateDimen
        -- to always use bottom_height = 0 for this instance.
        -- MosaicMenu also checks self.page_info:getSize().h in its override,
        -- so we nil that too during recalculation.
        -- We look up the class method dynamically (not captured at init time)
        -- because coverbrowser replaces _recalculateDimen on the class when
        -- switching between mosaic/list/classic display modes.
        self._recalculateDimen = function(self_inner, no_recalculate_dimen)
            local saved_arrow = self_inner.page_return_arrow
            local saved_text = self_inner.page_info_text
            local saved_info = self_inner.page_info
            self_inner.page_return_arrow = nil
            self_inner.page_info_text = nil
            self_inner.page_info = nil
            -- Temporarily remove instance override to call the current class method
            local instance_fn = self_inner._recalculateDimen
            self_inner._recalculateDimen = nil
            self_inner:_recalculateDimen(no_recalculate_dimen)
            self_inner._recalculateDimen = instance_fn
            self_inner.page_return_arrow = saved_arrow
            self_inner.page_info_text = saved_text
            self_inner.page_info = saved_info
        end

        self:_recalculateDimen()
    end
end


return apply_hide_pagination
