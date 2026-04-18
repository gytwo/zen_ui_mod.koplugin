local function apply_browser_preload_bookinfo()
    --[[
        Pre-populates the CoverBrowser metadata cache for all books in the current
        directory on every navigation (not just the visible page).
        Hooks FileChooser.refreshPath; delays 0.5 s so CoverMenu's page extraction
        gets the first subprocess slot. Backs off 8 s if still busy.
        Silently inert without CoverBrowser. Skips PathChooser/MoveChooser.
    ]]

    -- CoverBrowser plugin must be present; bail silently if it is not.
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok_bim or not BookInfoManager then return end

    local FileChooser = require("ui/widget/filechooser")
    local UIManager   = require("ui/uimanager")

    -- Track the last directory and item count for which we launched a pre-scan.
    -- Same-directory refreshes are skipped UNLESS the item count changed, which
    -- means files were added or removed (e.g. a book was just moved into this folder).
    local last_scanned_path  = nil
    local last_scanned_count = 0

    -- Capture plugin reference for live config reads inside callbacks.
    local _plugin = rawget(_G, "__ZEN_UI_PLUGIN")

    local function is_enabled()
        local p = _plugin or rawget(_G, "__ZEN_UI_PLUGIN")
        return not (p
            and type(p.config.browser_preload_bookinfo) == "table"
            and p.config.browser_preload_bookinfo.preload_bookinfo == false)
    end

    -- Attempt to launch a background extraction for any unindexed files.
    -- If CoverMenu's per-page subprocess is still running, backs off and retries.
    -- The item_table scan is chunked across scheduler ticks (CHUNK_SIZE items per
    -- tick) so a directory with thousands of books does not freeze the UI.
    local CHUNK_SIZE = 50

    local function run_preload(file_chooser, dir_path, cover_specs)
        -- Abort if the user navigated to a different directory while we waited.
        if file_chooser.path ~= dir_path then return end

        if BookInfoManager:isExtractingInBackground() then
            UIManager:scheduleIn(8, function()
                run_preload(file_chooser, dir_path, cover_specs)
            end)
            return
        end

        local item_table = file_chooser.item_table
        if not item_table then return end

        -- Scan item_table in CHUNK_SIZE slices, yielding between each so the
        -- UI thread stays responsive even with thousands of entries.
        local files    = {}
        local total    = #item_table
        local chunk_i  = 1

        local function process_chunk()
            -- Abort if the user has moved to another directory or toggled off.
            if file_chooser.path ~= dir_path then return end
            if not is_enabled() then return end

            local limit = math.min(chunk_i + CHUNK_SIZE - 1, total)
            for i = chunk_i, limit do
                local item = item_table[i]
                if item and item.is_file and item.path then
                    local bookinfo = BookInfoManager:getBookInfo(item.path, false)
                    if not bookinfo then
                        table.insert(files, { filepath = item.path, cover_specs = cover_specs })
                    elseif cover_specs and not bookinfo.ignore_cover then
                        if not bookinfo.cover_fetched then
                            table.insert(files, { filepath = item.path, cover_specs = cover_specs })
                        elseif bookinfo.has_cover
                                and BookInfoManager.isCachedCoverInvalid(bookinfo, cover_specs) then
                            table.insert(files, { filepath = item.path, cover_specs = cover_specs })
                        end
                    end
                end
            end
            chunk_i = limit + 1

            if chunk_i <= total then
                -- More items remain; yield for one scheduler tick then continue.
                UIManager:scheduleIn(0, process_chunk)
            elseif #files > 0 then
                -- All items scanned; kick off background extraction if still idle.
                if not BookInfoManager:isExtractingInBackground() then
                    BookInfoManager:extractInBackground(files)
                else
                    UIManager:scheduleIn(8, function()
                        if file_chooser.path == dir_path
                                and not BookInfoManager:isExtractingInBackground() then
                            BookInfoManager:extractInBackground(files)
                        end
                    end)
                end
            end
        end

        process_chunk()
    end

    -- Hook refreshPath so the pre-scan fires on:
    --   • FileManager first open (FileChooser:init → refreshPath)
    --   • Every directory navigation (changeToPath → refreshPath)
    local orig_refreshPath = FileChooser.refreshPath

    FileChooser.refreshPath = function(self, ...)
        orig_refreshPath(self, ...)

        -- Limit to the main FileManager; skip PathChooser / MoveChooser.
        if self.name ~= "filemanager" then return end
        if not is_enabled() then return end

        local path = self.path
        local item_count = self.item_table and #self.item_table or 0
        -- Skip same-directory refreshes only when the item count is unchanged.
        -- A changed count means files were added or removed, so we must re-scan.
        if path == last_scanned_path and item_count == last_scanned_count then return end
        last_scanned_path  = path
        last_scanned_count = item_count

        -- cover_specs is set on self by CoverBrowser's patched updateItems,
        -- which runs inside orig_refreshPath → switchItemTable → updateItems.
        -- Capture it now before any async delay.
        local cover_specs = self.cover_specs

        -- Short initial delay: let CoverMenu's nextTick-scheduled
        -- extractInBackground (for the current page) get a head start so it
        -- "wins" the first subprocess slot, then we handle the rest of the
        -- directory once it finishes.
        UIManager:scheduleIn(0.5, function()
            run_preload(self, path, cover_specs)
        end)
    end
end

return apply_browser_preload_bookinfo
