local function apply_browser_hide_finished()
    local FileChooser = require("ui/widget/filechooser")

    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    if not zen_plugin or type(zen_plugin.config) ~= "table" then
        return
    end

    local function is_enabled()
        local cfg = zen_plugin.config.browser_hide_finished
        return type(cfg) == "table" and cfg.hide_finished == true
    end

    local function is_finished(path)
        local ok_ds, DocSettings = pcall(require, "docsettings")
        if not ok_ds then return false end
        if not DocSettings:hasSidecarFile(path) then return false end
        local ok2, doc = pcall(DocSettings.open, DocSettings, path)
        if not ok2 or not doc then return false end
        local summary = doc:readSetting("summary") or {}
        return summary.status == "complete"
    end

    local orig_genItemTable = FileChooser.genItemTable

    function FileChooser:genItemTable(dirs, files, path)
        local item_table = orig_genItemTable(self, dirs, files, path)
        if not is_enabled() then
            return item_table
        end
        if self._dummy or self.name ~= "filemanager" then
            return item_table
        end

        local filtered = {}
        for _, item in ipairs(item_table) do
            if item.is_go_up or item.is_directory or not item.path
                or not is_finished(item.path) then
                table.insert(filtered, item)
            end
        end
        return filtered
    end
end

return apply_browser_hide_finished
