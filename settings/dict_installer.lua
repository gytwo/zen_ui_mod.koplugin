-- settings/dict_installer.lua
-- Dictionary download and installation utilities for Zen UI.

local _         = require("gettext")
local UIManager = require("ui/uimanager")
local logger    = require("logger")

local M = {}

M.SHORT_OXFORD =
    "aHR0cHM6Ly9kcml2ZS51c2VyY29udGVudC5nb29nbGUuY29tL2Rvd25sb2FkP2lkPTFiMlo4cXM4QlU1azlV"
    .. "NmxlOFZudnN5QTR3ZFNmWjlURyZleHBvcnQ9ZG93bmxvYWQmYXV0aHVzZXI9MCZjb25maXJtPXQmdXVpZD03"
    .. "Y2IwNzQyNS1mMzdhLTQ2ZGMtYmJlZi1lNzMxNjYzZTdmNDYmYXQ9QUxCd1Vna1BVV2hONjVvUjNSNmxuYWht"
    .. "VzdwSyUzQTE3NzY2MjU0MTc2MjM="

M.REGULAR_OXFORD =
    "aHR0cHM6Ly9kcml2ZS51c2VyY29udGVudC5nb29nbGUuY29tL2Rvd25sb2FkP2lkPTFZUTZlcVdENW1Da1Ez"
    .. "d1lzU1VoeWF5QV9ycEtGLWRIQiZleHBvcnQ9ZG93bmxvYWQmYXV0aHVzZXI9MCZjb25maXJtPXQmdXVpZD05"
    .. "YTlmYWZmYS00YTNhLTRiY2MtOThlZC01OTNkMmNlMWQ0ZTQmYXQ9QUxCd1VnbERMWkJ5MnhOTDltaFI3UV9i"
    .. "TzRGZiUzQTE3NzY2MjUzMzU5Mzg="

local function b64decode(data)
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    data = string.gsub(data, "[^" .. chars .. "=]", "")
    return (data:gsub(".", function(x)
        if x == "=" then return "" end
        local r, idx = "", (chars:find(x, 1, true) - 1)
        for i = 6, 1, -1 do r = r .. (idx % 2^i - idx % 2^(i-1) > 0 and "1" or "0") end
        return r
    end):gsub("%d%d%d%d%d%d%d%d", function(x)
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i, i) == "1" and 2^(8-i) or 0) end
        return string.char(c)
    end))
end

local function get_dict_dir()
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage then
        local settings_dir = type(DataStorage.getSettingsDir) == "function"
            and DataStorage:getSettingsDir() or nil
        if type(settings_dir) == "string" and settings_dir:sub(1, 1) == "/" then
            local koreader_root = settings_dir:match("^(.*)/[^/]+/?$")
            if koreader_root then
                logger.dbg("dict_install: koreader_root from DataStorage=", koreader_root)
                return koreader_root .. "/data/dict"
            end
        end
    end
    -- Fallback: walk up from this file's absolute path
    -- dict_installer.lua lives at <koreader_root>/plugins/<plugin>/settings/
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then
        local plugin_root = src:sub(2):match("^(.*)/settings/dict_installer%.lua$")
        if plugin_root then
            local plugins_dir   = plugin_root:match("^(.*)/[^/]+$")
            local koreader_root = plugins_dir and plugins_dir:match("^(.*)/[^/]+$")
            if koreader_root then
                logger.dbg("dict_install: koreader_root from src path=", koreader_root)
                return koreader_root .. "/data/dict"
            end
        end
    end
    return "/mnt/us/koreader/data/dict"
end

local function https_download(url, dest_path)
    local ok_ssl, https = pcall(require, "ssl.https")
    local ok_ltn, ltn12 = pcall(require, "ltn12")
    if not ok_ssl or not ok_ltn then
        logger.warn("dict_install: ssl.https or ltn12 not available")
        return false, "ssl.https not available"
    end

    logger.dbg("dict_install: starting download, url=", url)
    logger.dbg("dict_install: dest=", dest_path)

    local resolved_url = url
    for i = 1, 5 do
        local _, r_code, r_headers = https.request{
            url     = resolved_url,
            method  = "HEAD",
            headers = { ["User-Agent"] = "zen_ui.koplugin" },
            sink    = ltn12.sink.null(),
        }
        logger.dbg("dict_install: HEAD #" .. i .. " code=", r_code, "url=", resolved_url)
        if (r_code == 301 or r_code == 302 or r_code == 307 or r_code == 308)
            and r_headers and r_headers.location then
            resolved_url = r_headers.location
            logger.dbg("dict_install: redirect ->", resolved_url)
        else
            break
        end
    end

    local f, ferr = io.open(dest_path, "wb")
    if not f then
        logger.warn("dict_install: cannot open dest file:", ferr)
        return false, ferr
    end

    local _, dl_code = https.request{
        url     = resolved_url,
        headers = { ["User-Agent"] = "zen_ui.koplugin" },
        sink    = ltn12.sink.file(f),
    }
    pcall(f.close, f)
    logger.dbg("dict_install: GET response code=", dl_code)

    local fcheck = io.open(dest_path, "rb")
    if fcheck then
        local size = fcheck:seek("end")
        fcheck:close()
        logger.dbg("dict_install: file size on disk=", size)
    else
        logger.warn("dict_install: file not found on disk after download")
    end

    if dl_code ~= 200 then
        os.remove(dest_path)
        local msg = "HTTP " .. tostring(dl_code)
        logger.warn("dict_install: download failed:", msg)
        return false, msg
    end
    return true
end

function M.install(name, b64_url, notice)
    local InfoMessage = require("ui/widget/infomessage")
    local ConfirmBox  = require("ui/widget/confirmbox")

    local confirm_text = string.format(
        _("Install %s dictionary?\n\nThe file will be downloaded and installed."), name)
    if notice then
        confirm_text = confirm_text .. "\n\n" .. notice
    end

    UIManager:show(ConfirmBox:new{
        text        = confirm_text,
        ok_text     = _("Install"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            local progress = InfoMessage:new{ text = string.format(_("Downloading %s dictionary…"), name) }
            UIManager:show(progress)
            UIManager:forceRePaint()

            UIManager:scheduleIn(0.1, function()
                local dict_dir = get_dict_dir()
                logger.dbg("dict_install: dict_dir=", dict_dir)

                local url      = b64decode(b64_url)
                local zip_path = dict_dir .. "/dict_install.zip"
                logger.dbg("dict_install: decoded url length=", #url)

                local ok, err = https_download(url, zip_path)
                UIManager:close(progress)

                if not ok then
                    local msg = err or _("unknown error")
                    logger.warn("dict_install: aborting after download failure:", msg)
                    UIManager:show(InfoMessage:new{
                        text = _("Download failed: ") .. msg,
                    })
                    return
                end

                local tmp_dir = dict_dir .. "/_dict_tmp"
                os.execute(string.format("rm -rf %q", tmp_dir))
                logger.dbg("dict_install: unzipping to tmp=", tmp_dir)

                local unzip_cmd = string.format("unzip -o %q -d %q 2>&1", zip_path, tmp_dir)
                local handle    = io.popen(unzip_cmd)
                local unzip_out = handle and handle:read("*a") or ""
                local unzip_ok  = handle and handle:close()
                logger.dbg("dict_install: unzip output:", unzip_out)
                os.remove(zip_path)

                if not unzip_ok then
                    os.execute(string.format("rm -rf %q", tmp_dir))
                    logger.warn("dict_install: unzip failed:", unzip_out)
                    UIManager:show(InfoMessage:new{
                        text = _("Failed to unpack the dictionary.\n\n") .. (unzip_out or ""),
                    })
                    return
                end

                local ls_h   = io.popen(string.format("ls -1 %q 2>/dev/null", tmp_dir))
                local subdir = ls_h and ls_h:read("*l")
                if ls_h then ls_h:close() end
                logger.dbg("dict_install: zip subfolder=", subdir)

                if subdir and subdir ~= "" then
                    local subdir_path = tmp_dir .. "/" .. subdir
                    local mv_cmd = string.format(
                        "find %q -maxdepth 1 -mindepth 1 -exec mv {} %q/ \\; 2>&1",
                        subdir_path, dict_dir)
                    local mv_h   = io.popen(mv_cmd)
                    local mv_out = mv_h and mv_h:read("*a") or ""
                    if mv_h then mv_h:close() end
                    logger.dbg("dict_install: mv output:", mv_out)
                end

                os.execute(string.format("rm -rf %q", tmp_dir))
                logger.dbg("dict_install: done")

                UIManager:show(ConfirmBox:new{
                    text        = string.format(
                        _("%s dictionary installed successfully.\n\nRestart KOReader now to use it?"), name),
                    ok_text     = _("Restart now"),
                    cancel_text = _("Later"),
                    ok_callback = function()
                        local Event = require("ui/event")
                        UIManager:broadcastEvent(Event:new("Restart"))
                    end,
                })
            end)
        end,
    })
end

return M
