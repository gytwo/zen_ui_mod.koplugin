local function apply_context_menu()
    --[[
        Replaces the long-hold file/folder context menu in the file browser with
        a clean, minimal layout:

            New folder
            Move          (opens PathChooser to pick destination, then moves immediately)
            Add/Remove from favorites
            Edit ▶        (anchored submenu at right edge: Select · Rename · Delete · Cut · Copy · Paste)

        Everything else (book info, collections, open with, reset, status rows,
        scripts, converter, shortcuts, etc.) is intentionally hidden.
        No feature toggle – always active.
    ]]

    local BD           = require("ui/bidi")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Device       = require("device")
    local FileChooser  = require("ui/widget/filechooser")
    local FileManager  = require("apps/filemanager/filemanager")
    local Geom         = require("ui/geometry")
    local PathChooser  = require("ui/widget/pathchooser")
    local UIManager    = require("ui/uimanager")
    local Screen       = Device.screen
    local _            = require("gettext")
    local C_           = _.pgettext

    -- ── MoveChooser ───────────────────────────────────────────────────────────
    -- PathChooser subclass used by the Move action:
    --   • hides the go-up (..) row and the "long-press here" current-dir hint
    --   • single tap on a folder immediately confirms the move (no long-press)
    --   • folder covers render automatically via CoverBrowser (mosaic mode)
    local _orig_fc_genItemTable = FileChooser.genItemTable
    local MoveChooser = PathChooser:extend{}

    function MoveChooser:genItemTable(dirs, files, path)
        local items = _orig_fc_genItemTable(self, dirs, files, path)
        local filtered = {}
        for _, item in ipairs(items) do
            -- skip ".." (go-up) and "." (choose-current-dir-for-hold) entries
            if not item.is_go_up
               and (not item.path or not item.path:match("/%./?$"))
            then
                table.insert(filtered, item)
            end
        end
        return filtered
    end

    function MoveChooser:onMenuSelect(item)
        local path = item and item.path
        if not path then return true end
        local ffiUtil2 = require("ffi/util")
        local real     = ffiUtil2.realpath(path)
        if not real then return true end
        local lfs2 = require("libs/libkoreader-lfs")
        if lfs2.attributes(real, "mode") == "directory" then
            if self.onConfirm then self.onConfirm(real) end
            UIManager:close(self)
        end
        return true
    end
    -- ─────────────────────────────────────────────────────────────────────────

    local orig_setupLayout = FileManager.setupLayout

    FileManager.setupLayout = function(self)
        orig_setupLayout(self)

        local file_chooser = self.file_chooser
        local file_manager = self

        -- Replace the instance-level showFileDialog defined by setupLayout
        file_chooser.showFileDialog = function(self_fc, item)
            local file               = item.path
            local is_file            = item.is_file
            local is_not_parent_folder = not item.is_go_up

            local function close_dialog()
                UIManager:close(self_fc.file_dialog)
            end

            local function refresh()
                self_fc:refreshPath()
            end

            -- ── Edit submenu (anchored to right edge so it appears beside main dialog) ──
            local function showEditSubmenu()
                -- Keep main dialog open; layer the edit dialog on top anchored right.
                local edit_dialog
                local sw = Screen:getWidth()
                local sh = Screen:getHeight()
                -- anchor: a slim rect on the right edge, vertically centered
                local anchor = Geom:new{ x = sw - 1, y = math.floor(sh * 0.25),
                                         w = 1, h = math.floor(sh * 0.5) }

                local edit_buttons = {
                    {
                        {
                            text     = _("Select"),
                            callback = function()
                                UIManager:close(edit_dialog)
                                close_dialog()
                                file_manager:onToggleSelectMode()
                                if is_file then
                                    file_manager.selected_files[file] = true
                                    item.dim = true
                                    self_fc:updateItems(1, true)
                                end
                            end,
                        },
                        {
                            text     = _("Rename"),
                            enabled  = is_not_parent_folder,
                            callback = function()
                                UIManager:close(edit_dialog)
                                close_dialog()
                                file_manager:showRenameFileDialog(file, is_file)
                            end,
                        },
                    },
                    {
                        {
                            text     = _("Delete"),
                            enabled  = is_not_parent_folder,
                            callback = function()
                                UIManager:close(edit_dialog)
                                close_dialog()
                                file_manager:showDeleteFileDialog(file, refresh)
                            end,
                        },
                        {
                            text     = _("Cut"),
                            enabled  = is_not_parent_folder,
                            callback = function()
                                UIManager:close(edit_dialog)
                                close_dialog()
                                file_manager:cutFile(file)
                            end,
                        },
                    },
                    {
                        {
                            text     = C_("File", "Copy"),
                            enabled  = is_not_parent_folder,
                            callback = function()
                                UIManager:close(edit_dialog)
                                close_dialog()
                                file_manager:copyFile(file)
                            end,
                        },
                        {
                            text     = C_("File", "Paste"),
                            enabled  = file_manager.clipboard and true or false,
                            callback = function()
                                UIManager:close(edit_dialog)
                                close_dialog()
                                file_manager:pasteFileFromClipboard(file)
                            end,
                        },
                    },
                }

                edit_dialog = ButtonDialog:new{
                    anchor      = anchor,
                    buttons     = edit_buttons,
                }
                UIManager:show(edit_dialog)
            end

            -- ── Main dialog ───────────────────────────────────────────────────
            local buttons = {
                {
                    {
                        text     = _("New folder"),
                        callback = function()
                            close_dialog()
                            file_manager:createFolder()
                        end,
                    },
                },
            }

            if is_not_parent_folder then
                -- Move: open a folder picker then immediately execute the move
                table.insert(buttons, {
                    {
                        text     = _("Move"),
                        callback = function()
                            close_dialog()
                            local ffiUtil     = require("ffi/util")
                            local DocSettings = require("docsettings")
                            local ReadHistory = require("readhistory")
                            local ReadCollection = require("readcollection")
                            local lfs         = require("libs/libkoreader-lfs")
                            local src         = ffiUtil.realpath(file)
                            local chooser = MoveChooser:new{
                                select_directory = true,
                                select_file      = false,
                                show_files       = false,
                                title            = _"Move to…",
                                path             = ffiUtil.dirname(src),
                                onConfirm        = function(dest_dir)
                                    local dest_dir_real = ffiUtil.realpath(dest_dir)
                                    if not dest_dir_real then return end
                                    -- bail if destination is same directory
                                    if dest_dir_real == ffiUtil.realpath(ffiUtil.dirname(src)) then
                                        return
                                    end
                                    local name     = ffiUtil.basename(src)
                                    local dest_file = ffiUtil.joinPath(dest_dir_real, name)
                                    if lfs.attributes(dest_file) then
                                        local InfoMessage = require("ui/widget/infomessage")
                                        UIManager:show(InfoMessage:new{
                                            text = _("An item with that name already exists."),
                                            icon = "notice-warning",
                                        })
                                        return
                                    end
                                    if file_manager:moveFile(src, dest_dir_real) then
                                        if is_file then
                                            DocSettings.updateLocation(src, dest_file)
                                            ReadHistory:updateItem(src, dest_file)
                                            ReadCollection:updateItem(src, dest_file)
                                        else
                                            ReadHistory:updateItemsByPath(src, dest_file)
                                            ReadCollection:updateItemsByPath(src, dest_file)
                                        end
                                        refresh()
                                    else
                                        local InfoMessage = require("ui/widget/infomessage")
                                        UIManager:show(InfoMessage:new{
                                            text = _("Move failed."),
                                            icon = "notice-warning",
                                        })
                                    end
                                end,
                            }
                            UIManager:show(chooser)
                        end,
                    },
                })
            end

            if is_file then
                local ReadCollection = require("readcollection")
                local default_coll   = ReadCollection.default_collection_name
                local is_fav         = ReadCollection:isFileInCollection(file, default_coll)

                table.insert(buttons, {
                    {
                        text = is_fav and _("Remove from favorites") or _("Add to favorites"),
                        callback = function()
                            close_dialog()
                            if is_fav then
                                ReadCollection:removeItem(file, default_coll)
                            else
                                ReadCollection:addItem(file, default_coll)
                            end
                            ReadCollection:write({ [default_coll] = true })
                        end,
                    },
                })
            end

            table.insert(buttons, {
                {
                    text     = _("Edit  ▶"),
                    callback = showEditSubmenu,
                },
            })

            self_fc.file_dialog = ButtonDialog:new{
                title       = is_file
                    and BD.filename(file:match("([^/]+)$"))
                    or  BD.directory(file:match("([^/]+)$")),
                title_align = "center",
                buttons     = buttons,
            }
            UIManager:show(self_fc.file_dialog)
            return true
        end
    end
end

return apply_context_menu
