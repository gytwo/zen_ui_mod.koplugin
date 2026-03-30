local function apply_book_status()
    -- Always redirect end-of-book to the Book Status screen
    local ReaderStatus = require("apps/reader/modules/readerstatus")

    local orig_onEndOfBook = ReaderStatus.onEndOfBook
    ReaderStatus.onEndOfBook = function(self)
        return self:onShowBookStatus()
    end

    -- Always use the Zen UI custom Book Status layout (home + close buttons, cleaner stats)
    local BookStatusWidget = require("ui/widget/bookstatuswidget")

    BookStatusWidget.getStatusContent = function(self, width)
        local _ = require("gettext")
        local Size = require("ui/size")
        local Device = require("device")
        local Screen = Device.screen
        local IconButton = require("ui/widget/iconbutton")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan = require("ui/widget/horizontalspan")
        local VerticalGroup = require("ui/widget/verticalgroup")
        local VerticalSpan = require("ui/widget/verticalspan")
        local UIManager = require("ui/uimanager")

        -- Build a custom header row instead of TitleBar so both icons share the
        -- same HorizontalGroup centerline, compensating for the home SVG's
        -- built-in top whitespace that TitleBar's top-aligned OverlapGroup exposes.
        local DGENERIC_ICON_SIZE = G_defaults:readSetting("DGENERIC_ICON_SIZE")
        local close_size = Screen:scaleBySize(DGENERIC_ICON_SIZE * 0.85)
        local home_size  = Screen:scaleBySize(DGENERIC_ICON_SIZE * 1.1)
        local btn_pad    = Screen:scaleBySize(6)

        local home_callback = function()
            local ui = self.ui
            local file = ui and ui.document and ui.document.file
            if self.updated then
                ui.doc_settings:flush()
            end
            UIManager:close(self)
            if ui and ui.document then
                ui:onClose()
                if type(ui.showFileManager) == "function" then
                    ui:showFileManager(file)
                end
            end
        end

        local close_btn = IconButton:new{
            icon = "close",
            width = close_size, height = close_size,
            padding = btn_pad,
            show_parent = self,
            callback = function() self:onClose() end,
            allow_flash = false,
        }
        local home_btn = IconButton:new{
            icon = "home",
            width = home_size, height = home_size,
            padding = btn_pad,
            show_parent = self,
            callback = home_callback,
        }

        -- Center-align keeps both icons on the same horizontal midline
        local header_row = HorizontalGroup:new{
            align = "center",
            close_btn,
            HorizontalSpan:new{ width = width - (close_size + btn_pad * 2) - (home_size + btn_pad * 2) },
            home_btn,
        }
        local title_bar = VerticalGroup:new{
            header_row,
            VerticalSpan:new{ width = Size.padding.default },
        }

        -- Reduce the large top gap above the Statistics header (was Size.item.height_default ~48px)
        local stats_header = self:genHeader(_("Statistics"))
        if stats_header and stats_header[1] then
            stats_header[1].width = Size.span.vertical_default
        end

        local summary_group = self:genSummaryGroup(width)
        -- Only open review dialog when the tap is within the note frame bounds
        if self.note_frame then
            self.note_frame.onGesture = function(frame, ev)
                if ev and ev.ges == "tap" and ev.pos
                        and frame.dimen and frame.dimen:contains(ev.pos) then
                    return self:openReviewDialog()
                end
            end
        end

        return VerticalGroup:new{
            align = "left",
            title_bar,
            self:genBookInfoGroup(),
            stats_header,
            self:genStatisticsGroup(width),
            self:genHeader(_("Review")),
            summary_group,
            self:genHeader(self.readonly and _("Book Status") or _("Update Status")),
            self:generateSwitchGroup(width),
        }
    end
end

return apply_book_status
