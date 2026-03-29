local function apply_subfolder_padding()
    --[[
        Prepends a vertical spacer to the file-chooser item group whenever the
        current path is a subfolder of home_dir.  This pushes items below the
        extra folder-title row that titlebar.lua draws, which overflows the
        fixed TitleBar dimen.h into the item area.

        Implemented as a standalone FileChooser.updateItems hook so it fires
        at the correct time (after every item list rebuild) without any
        dependency on titlebar's internal state or nextTick scheduling.
    ]]

    local Device       = require("device")
    local FileChooser  = require("ui/widget/filechooser")
    local Font         = require("ui/font")
    local TextWidget   = require("ui/widget/textwidget")
    local VerticalSpan = require("ui/widget/verticalspan")
    local Screen       = Device.screen

    -- Measure folder-title row height using the same font as the folder row
    -- in titlebar.lua (NotoSans-Bold at x_smallinfofont size).
    local function getFolderRowHeight()
        local face = Font:getFace("NotoSans-Bold.ttf", Font.sizemap["x_smallinfofont"])
        local tw = TextWidget:new{ text = "A", face = face, bold = true }
        local h  = tw:getSize().h
        tw:free()
        return h
    end

    -- Check whether path is a strict subfolder of home_dir.
    local function isSubfolder(path)
        if not path then return false end
        local g_settings = rawget(_G, "G_reader_settings")
        local home_dir   = g_settings and g_settings:readSetting("home_dir")
        if not home_dir then return false end
        local norm_home = home_dir:gsub("/$", "")
        local norm_path = path:gsub("/$",  "")
        return norm_path ~= norm_home
            and norm_path:sub(1, #norm_home + 1) == norm_home .. "/"
    end

    -- Only hook once, even if this module is required multiple times.
    if FileChooser._zen_subfolder_padding_hooked then return end
    FileChooser._zen_subfolder_padding_hooked = true

    local orig_updateItems = FileChooser.updateItems

    FileChooser.updateItems = function(self, ...)
        orig_updateItems(self, ...)

        if not isSubfolder(self.path) then return end
        if not self.item_group      then return end

        local pad = getFolderRowHeight()
        if pad > 0 then
            table.insert(self.item_group, 1, VerticalSpan:new{ width = pad })
            self.item_group:resetLayout()
        end
    end
end

return apply_subfolder_padding
