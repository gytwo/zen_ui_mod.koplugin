local function apply_margin_hold_guard()
    --[[
        Swallows onHold gestures that land inside the page margin area to prevent
        accidental word selection when a palm or thumb rests on the edge of the screen.

        Only applies to reflowable (CRE / EPUB-like) documents. PDF and similar
        paging documents are left untouched ("forget pdf").

        getPageMargins() on a CRE document returns the four rendered margin sizes
        in screen pixels, matching whatever the user has set (small, medium, large,
        custom, etc.).  We compare the raw screen-space gesture coordinates against
        those insets:

          • Left / right margins  – always guarded regardless of view mode.
          • Top / bottom margins  – guarded in page mode only.  In scroll mode the
            viewport can be sitting in the middle of a chapter, so the margin strip
            is not at a fixed screen edge and checking y would produce false positives.
    --]]

    local ReaderHighlight = require("apps/reader/modules/readerhighlight")
    local Device = require("device")
    local Screen = Device.screen

    local _onHold_orig = ReaderHighlight.onHold

    ReaderHighlight.onHold = function(self, arg, ges)
        -- PDF / DjVu / CBZ – do not interfere.
        if self.ui.paging then
            return _onHold_orig(self, arg, ges)
        end

        local ok, margins = pcall(function()
            return self.ui.document:getPageMargins()
        end)

        if ok and type(margins) == "table" then
            local x  = ges.pos.x
            local y  = ges.pos.y
            local sw = Screen:getWidth()
            local sh = Screen:getHeight()

            -- Horizontal margins (left / right) – reliable in every view mode.
            local left  = margins["left"]  or 0
            local right = margins["right"] or 0
            if x < left or x > sw - right then
                return false
            end

            -- Vertical margins (top / bottom) – only in page mode.
            if self.view and self.view.view_mode == "page" then
                local top    = margins["top"]    or 0
                local bottom = margins["bottom"] or 0
                if y < top or y > sh - bottom then
                    return false
                end
            end
        end

        return _onHold_orig(self, arg, ges)
    end
end

return apply_margin_hold_guard
