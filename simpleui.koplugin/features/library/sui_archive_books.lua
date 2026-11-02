-- sui_archive_books.lua — Simple UI
-- Finished books are collected into one real folder in the library, so they
-- can be put away without losing their sidecars (progress, bookmarks,
-- highlights). The folder is an ordinary directory: the native file browser
-- lists it, and the books inside it stay readable.
--
-- "Put it last" means two things:
--   * in the file browser the archive folder is sorted after every other
--     folder of the same directory (see install());
--   * the flat shelf (module_library.lua) does not list the books inside it
--     — archiving is what takes them off the shelf (see LibraryScan's
--     skipped folder names).
--
-- Public API
-- ----------
--   Archive.folderName()             -> string   the folder's name
--   Archive.folder()                 -> string   absolute path, or nil
--   Archive.isArchived(path)         -> boolean
--   Archive.archive(file)            -> ok, err  move a book into the folder
--   Archive.unarchive(file)          -> ok, err  move it back out
--   Archive.list()                   -> { fp, ... } the books in the folder
--   Archive.isEnabled()              -> boolean  auto-archive on finish
--   Archive.setEnabled(on)
--   Archive.makeMenuItems(ctx_menu)   -> { item, ... }
--   Archive.registerHoldAction(fm)   -> long-press row
--   Archive.install() / Archive.uninstall()

local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local ffiUtil     = require("ffi/util")
local SUISettings = require("infra/sui_store")
local UI          = require("infra/sui_core")
local _           = require("infra/sui_i18n").translate

local Archive = {}

-- The folder is created on demand, so the default name only matters once
-- the first finished book is archived. Kept in English so it sorts the
-- same way on every device; the label shown in the UI is translated.
local DEFAULT_FOLDER = "Finished"
local FOLDER_KEY     = "simpleui_archive_folder_name"
local ENABLED_KEY    = "simpleui_archive_finished_enabled"

-- The mv binary of the device, the same one the file manager uses
-- (FileManager.mv_bin). On Android it lives in /system/bin, elsewhere in
-- /bin.
local MV_BIN = (function()
    local ok, Device = pcall(require, "device")
    if ok and Device and Device.isAndroid and Device:isAndroid() then
        return "/system/bin/mv"
    end
    return "/bin/mv"
end)()

--- The name of the archive folder. User-configurable, never empty.
function Archive.folderName()
    local name = SUISettings:get(FOLDER_KEY)
    if type(name) ~= "string" or name == "" then return DEFAULT_FOLDER end
    return name
end

function Archive.setFolderName(name)
    if type(name) ~= "string" then return end
    name = name:gsub("[/\\:%*%?\"<>|]", "_"):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then name = DEFAULT_FOLDER end
    SUISettings:set(FOLDER_KEY, name)
end

--- Whether a finished book is moved into the archive automatically.
function Archive.isEnabled() return SUISettings:nilOrTrue(ENABLED_KEY) end
function Archive.setEnabled(on) SUISettings:set(ENABLED_KEY, on and true or false) end

--- The library folder the archive lives in. Identical to the upload
--- target (features/sui_upload_web.lua): the resolved home dir, and the
--- "documents" child of the device home dir when it cannot be resolved.
local function libraryDir()
    local ok, home = pcall(function()
        return require("engines/sui_library_scan").resolveHomeDir()
    end)
    if ok and type(home) == "string" and home ~= "" then return home end
    local Device = require("device")
    local base = Device.home_dir or "/mnt/us"
    if base:sub(-1) == "/" then base = base:sub(1, -2) end
    return base .. "/documents"
end

--- Absolute path of the archive folder, or nil when the library folder is
--- unknown.
function Archive.folder()
    local dir = libraryDir()
    if not dir or dir == "" then return nil end
    return dir .. "/" .. Archive.folderName()
end

--- True when `path` is the archive folder or lives inside it.
function Archive.isArchived(path)
    if type(path) ~= "string" or path == "" then return false end
    local folder = Archive.folder()
    if not folder then return false end
    return path == folder or path:sub(1, #folder + 1) == folder .. "/"
end

--- Creates the archive folder if it is missing. Returns the path or nil.
local function ensureFolder()
    local folder = Archive.folder()
    if not folder then return nil end
    if lfs.attributes(folder, "mode") == "directory" then return folder end
    if lfs.attributes(folder, "mode") == "file" then
        logger.warn("simpleui archive: path exists and is a file:", folder)
        return nil
    end
    local ok = pcall(lfs.mkdir, folder)
    if ok and lfs.attributes(folder, "mode") == "directory" then return folder end
    logger.warn("simpleui archive: cannot create folder", folder)
    return nil
end

--- The books currently in the archive folder.
function Archive.list()
    local folder = Archive.folder()
    local out = {}
    if not folder then return out end
    local ok, iter, dir_obj = pcall(lfs.dir, folder)
    if not ok or type(iter) ~= "function" then return out end
    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." and entry:sub(-4) ~= ".sdr" then
            local fp = folder .. "/" .. entry
            if lfs.attributes(fp, "mode") == "file" then out[#out + 1] = fp end
        end
    end
    table.sort(out)
    return out
end

--- Moves `file` (with its sidecar, history and collection entries) into the
--- archive folder. Returns ok, err.
local move

function Archive.archive(file)
    if type(file) ~= "string" or file == "" then return false, "no file" end
    if Archive.isArchived(file) then return false, "already archived" end
    local folder = ensureFolder()
    if not folder then return false, "no folder" end
    return move(file, folder)
end

--- Moves `file` back out of the archive folder, into the library folder.
function Archive.unarchive(file)
    if type(file) ~= "string" or file == "" then return false, "no file" end
    if not Archive.isArchived(file) then return false, "not archived" end
    local dir = libraryDir()
    if not dir or dir == "" then return false, "no library" end
    return move(file, dir)
end

-- Moves a book into `dest_dir`, carrying its sidecar along and updating the
-- reading history and the collections, exactly like the file manager's
-- paste does (see filemanager.lua's pasteFileFromClipboard).
move = function(file, dest_dir)
    local name = ffiUtil.basename(file)
    if not name or name == "" then return false, "no name" end
    local dest_file = ffiUtil.joinPath(dest_dir, name)
    if dest_file == file then return false, "same path" end
    if lfs.attributes(dest_file, "mode") then
        return false, "a file with that name is already there"
    end

    -- The move itself: the device's own mv binary, like FileManager:moveFile
    -- ffiUtil.execute uses execl, which requires an explicit binary path.
    if ffiUtil.execute(MV_BIN, "-f", file, dest_file) ~= 0 then
        logger.warn("simpleui archive: move failed", file, dest_file)
        return false, "move failed"
    end

    -- Sidecar (progress, bookmarks, highlights). The metadata follows the
    -- book to its new location; the old one is purged.
    pcall(function()
        local DocSettings = require("docsettings")
        DocSettings.updateLocation(file, dest_file, false)
    end)

    -- Reading history and collections still point at the old path.
    pcall(function()
        require("readhistory"):updateItem(file, dest_file)
    end)
    pcall(function()
        require("readcollection"):updateItem(file, dest_file)
    end)

    -- The shelf caches the library listing; let it see the move.
    pcall(function()
        require("engines/sui_library_scan").invalidate()
    end)

    logger.info("simpleui archive: moved", file, "->", dest_file)
    return true
end

-- ---------------------------------------------------------------------------
-- File browser: the archive folder is sorted last
-- ---------------------------------------------------------------------------

local _orig_gen_item_table = nil

--- Put the archive last after KOReader has sorted folders and files.
function Archive.install()
    if _orig_gen_item_table then return end
    local ok, FileChooser = pcall(require, "ui/widget/filechooser")
    if not ok or not FileChooser or not FileChooser.genItemTable then return end

    -- The shelf does not list the archived books: archiving is what takes
    -- them off it. The folder's name is a setting, so it is registered
    -- with the scanner instead of being hard-coded there.
    pcall(function()
        require("engines/sui_library_scan").skipDirName(Archive.folderName())
    end)

    _orig_gen_item_table = FileChooser.genItemTable
    FileChooser.genItemTable = function(fc_self, dirs, files, path)
        local items = _orig_gen_item_table(fc_self, dirs, files, path)
        local folder = Archive.folder()
        if type(items) == "table" then
            for i, item in ipairs(items) do
                if item.path == folder and not item.is_go_up then
                    table.remove(items, i)
                    items[#items + 1] = item
                    break
                end
            end
        end
        return items
    end
end

function Archive.uninstall()
    if not _orig_gen_item_table then return end
    local FileChooser = package.loaded["ui/widget/filechooser"]
    if FileChooser then FileChooser.genItemTable = _orig_gen_item_table end
    _orig_gen_item_table = nil
end

-- ---------------------------------------------------------------------------
-- Long-press action
-- ---------------------------------------------------------------------------

--- The row offered on a book's action sheet: archive it, or take it back
--- out of the archive.
function Archive.registerHoldAction(fm)
    fm:addFileDialogButtons("sui_archive_book", function(file, is_file, book_props, close)
        if not is_file then return nil end
        if Archive.isArchived(file) then
            return {{
                text     = _("Take out of the archive"),
                sui_icon = "folder",
                callback = function()
                    local ok, err = Archive.unarchive(file)
                    if not ok then
                        UI.Notify.toast(err == "a file with that name is already there"
                            and _("There is already a book with that name in the library.")
                            or _("Could not move the book."))
                    end
                    if close then close() end
                end,
            }}
        end
        return {{
            text     = _("Move to the archive"),
            sui_icon = "folder",
            callback = function()
                local ok, err = Archive.archive(file)
                if not ok then
                    UI.Notify.toast(err == "a file with that name is already there"
                        and _("There is already a book with that name in the archive.")
                        or _("Could not move the book."))
                end
                if close then close() end
            end,
        }}
    end)
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

--- The settings rows: turn archiving on or off, and open the archive.
function Archive.makeMenuItems(ctx_menu)
    local refresh = ctx_menu and ctx_menu.refresh
    local items = {}

    items[#items + 1] = {
        text           = _("Move finished books to the archive"),
        checked_func   = Archive.isEnabled,
        keep_menu_open = true,
        callback       = function()
            Archive.setEnabled(not Archive.isEnabled())
            if refresh then refresh() end
        end,
    }

    items[#items + 1] = {
        text     = _("Archive folder"),
        callback = function()
            require("features/dialogs/sui_dialogs").prompt{
                title        = _("Archive folder"),
                description  = _("The folder finished books are moved into. It is created inside your library."),
                value        = Archive.folderName(),
                ok_text      = _("OK"),
                on_submit    = function(name)
                    Archive.setFolderName(name)
                    if refresh then refresh() end
                end,
            }
        end,
    }

    items[#items + 1] = {
        text     = _("Open the archive"),
        callback = function()
            local folder = ensureFolder()
            if not folder then
                UI.Notify.toast(_("Could not create the archive folder."))
                return
            end
            local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
            local fm = ok_fm and FM and FM.instance
            if not fm then return end
            local fc = fm.file_chooser
            if not fc then return end
            fc:changeToPath(folder)
        end,
    }

    return items
end

return Archive
