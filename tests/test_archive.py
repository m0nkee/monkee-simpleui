"""Exercise the shipped archive callbacks, including real temporary file moves."""
from pathlib import Path
import subprocess
import tempfile
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1] / 'simpleui.koplugin'
lua = LuaRuntime(unpack_returned_tuples=True)

with tempfile.TemporaryDirectory() as tmp:
    home = Path(tmp)
    book = home / 'book.epub'
    book.write_bytes(b'book fixture')
    sidecar = home / 'book.epub.sdr'
    sidecar.mkdir()
    (sidecar / 'metadata.lua').write_text('progress and annotations')

    def attributes(path, key=None):
        p = Path(path)
        if not p.exists():
            return None
        result = {'mode': 'directory' if p.is_dir() else 'file'}
        return result.get(key) if key else lua.table_from(result)

    def execute(*args):
        return subprocess.run(args, capture_output=True).returncode

    def update_location(src, dst, copy):
        assert copy is False
        Path(src + '.sdr').rename(dst + '.sdr')

    lua.globals().plugin_root = str(ROOT)
    lua.globals().home = tmp
    lua.globals().attributes = attributes
    lua.globals().mkdir = lambda p: Path(p).mkdir()
    lua.globals().execute = execute
    lua.globals().update_location = update_location
    lua.execute(r'''
package.path = plugin_root.."/?.lua;"..package.path
package.loaded["logger"] = {info=function() end, warn=function() end}
package.loaded["libs/libkoreader-lfs"] = {attributes=attributes, mkdir=mkdir}
package.loaded["ffi/util"] = {
 basename=function(p) return p:match("([^/]+)$") end,
 joinPath=function(a,b) return a.."/"..b end, execute=execute,
}
local stored = {}
package.loaded["infra/sui_store"] = {
 get=function(_,k) return stored[k] end,
 set=function(_,k,v) stored[k]=v end,
 nilOrTrue=function(_,k) return stored[k]~=false end,
}
package.loaded["infra/sui_i18n"] = {translate=function(s) return s end}
package.loaded["infra/sui_core"] = {Notify={toast=function(s) error(s) end}}
package.loaded["device"] = {isAndroid=function() return false end}
local invalidated, history, collection = 0, 0, 0
package.loaded["engines/sui_library_scan"] = {
 resolveHomeDir=function() return home end,
 skipDirName=function() end,
 invalidate=function() invalidated=invalidated+1 end,
}
package.loaded["docsettings"] = {updateLocation=update_location}
package.loaded["readhistory"] = {updateItem=function() history=history+1 end}
package.loaded["readcollection"] = {updateItem=function() collection=collection+1 end}
local Archive = require("features/library/sui_archive_books")
local row, closed
Archive.registerHoldAction({addFileDialogButtons=function(_,id,fn) row=fn end})
local source, target = home.."/book.epub", home.."/Finished/book.epub"
row(source,true,nil,function() closed=true end)[1].callback()
assert(closed and not attributes(source) and attributes(target), "archive callback moves the book")
assert(attributes(target..".sdr"), "sidecar follows the book")
assert(history==1 and collection==1 and invalidated==1, "all paths and caches updated")
local ok,err=Archive.archive(target)
assert(not ok and err=="already archived")
-- Refuse a collision, preserving both copies.
local f=assert(io.open(source,"wb")); f:write("existing"); f:close()
ok=Archive.unarchive(target)
assert(not ok and attributes(source) and attributes(target), "never overwrite a book")
assert(os.remove(source))
closed=false
row(target,true,nil,function() closed=true end)[1].callback()
assert(closed and attributes(source) and not attributes(target), "restore callback moves it back")
assert(attributes(source..".sdr") and history==2 and collection==2 and invalidated==2)
-- A failed move must leave the sidecar and history alone.
ok=Archive.archive(home.."/missing.epub")
assert(not ok and history==2 and collection==2 and invalidated==2)

-- The delegate sorts internally, like KOReader. Moving its input is undone.
local FC={}
function FC:genItemTable(dirs,files,path)
 local items={}
 for _,d in ipairs(dirs) do items[#items+1]=d end
 for _,f in ipairs(files) do items[#items+1]=f end
 table.sort(items,function(a,b) return a.path<b.path end)
 table.insert(items,1,{path=path.."/..",is_go_up=true})
 return items
end
local original=FC.genItemTable
package.loaded["ui/widget/filechooser"]=FC
Archive.install(); Archive.install()
local result=FC:genItemTable({{path=home.."/Finished"},{path=home.."/Zebra"}},
 {{path=home.."/book.epub"}},home)
assert(result[1].is_go_up and result[#result].path==home.."/Finished", "archive sorts last after delegate")
assert(result[2].path==home.."/Zebra" and result[3].path==home.."/book.epub")
Archive.uninstall()
assert(FC.genItemTable==original, "teardown restores original")
''')
    assert book.read_bytes() == b'book fixture'
    assert (sidecar / 'metadata.lua').read_text() == 'progress and annotations'

print('PASS: archive/restore callbacks, sidecars, collisions, failed moves, sorting and teardown.')
