-- zen_ui: bookmarks patch
-- Makes page numbers in the bookmark/highlight list slightly larger and
-- always renders them in black (instead of dimming future-page entries to gray).

local function apply_bookmarks()
    local ReaderBookmark = require("apps/reader/modules/readerbookmark")

    local _orig_onShowBookmark = ReaderBookmark.onShowBookmark

    ReaderBookmark.onShowBookmark = function(self, ...)
        _orig_onShowBookmark(self, ...)

        local bm_menu = self.bookmark_menu and self.bookmark_menu[1]
        if not bm_menu then return end

        -- Default mandatory (page number) font size is font_size - 4.
        -- Use font_size - 2 for a slightly larger page number.
        bm_menu.items_mandatory_font_size = (bm_menu.font_size or 18) - 2

        -- Wrap the instance's updateItems so that every subsequent re-render
        -- (page turns, filter/sort, bulk-select) also clears mandatory_dim,
        -- keeping page numbers in black.
        if not bm_menu._zen_bm_patched then
            bm_menu._zen_bm_patched = true
            local _orig_updateItems = bm_menu.updateItems
            bm_menu.updateItems = function(self_m, ...)
                for _, item in ipairs(self_m.item_table or {}) do
                    item.mandatory_dim = nil
                end
                return _orig_updateItems(self_m, ...)
            end
        end

        -- Apply immediately to items already built by onShowBookmark.
        for _, item in ipairs(bm_menu.item_table) do
            item.mandatory_dim = nil
        end
        bm_menu:updateItems(1, true)
    end
end

return apply_bookmarks
