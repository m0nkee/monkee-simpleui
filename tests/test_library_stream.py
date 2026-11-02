"""Scroll through a large shelf with bounded widgets and stable anchors."""
from pathlib import Path
import re
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1] / 'simpleui.koplugin'
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().plugin_root = str(ROOT)
lua.execute(r'''
package.path=plugin_root.."/?.lua;"..package.path
local Stream=require("engines/sui_library_stream")
local files={}
for i=1,1003 do files[i]="book-"..i end
local ctx={}
local visible,rows=Stream.slice(ctx,"shelf",files,5)
assert(#visible==30 and rows==6 and visible[1]==files[1])
local seen={}
while true do
 visible=Stream.slice(ctx,"shelf",files,5)
 assert(#visible<=60,"bounded cover widgets")
 for _,file in ipairs(visible) do seen[file]=true end
 local shift=Stream.advance(ctx,"shelf",1)
 if shift==nil then break end
 assert(shift<=0,"trimmed rows subtract from scroll offset")
end
for _,file in ipairs(files) do assert(seen[file],"skipped "..file) end
assert(visible[#visible]==files[#files],"partial final row remains reachable")
local last=visible[1]
assert(Stream.advance(ctx,"shelf",-1)>0,"prepend rows when scrolling back")
visible=Stream.slice(ctx,"shelf",files,5)
assert(visible[1]~=last)
while Stream.advance(ctx,"shelf",-1)~=nil do end
visible=Stream.slice(ctx,"shelf",files,5)
assert(visible[1]==files[1],"can return to the first book")
assert(Stream.advance(ctx,"shelf",-1)==nil)

-- Cache invalidation with identical contents retains position. Sorting,
-- new books and changing columns start a fresh window.
Stream.advance(ctx,"shelf",1)
local before=ctx._library_streams.shelf.first
local clone={};for i,file in ipairs(files) do clone[i]=file end
Stream.slice(ctx,"shelf",clone,5)
assert(ctx._library_streams.shelf.first==before)
local reordered={};for i,file in ipairs(clone) do reordered[i]=file end
reordered[1],reordered[2]=reordered[2],reordered[1]
visible,rows=Stream.slice(ctx,"shelf",reordered,5)
assert(rows==6 and visible[1]==files[2])
visible,rows=Stream.slice(ctx,"shelf",files,4)
assert(#visible==24 and rows==6)
assert(#Stream.slice({},"shelf",{},5)==0)
assert(#Stream.slice({},"shelf",{"one"},5)==1)

-- Run the actual scroll hook with a native-style scroll/refresh contract.
local tasks={}
package.loaded["ui/uimanager"]={nextTick=function(_,fn) tasks[#tasks+1]=fn end}
ctx={}; Stream.slice(ctx,"flat_library",files,5)
local scroll={dimen={y=0,h=300},_scroll_offset_y=0}
function scroll:_scrollBy(_,dy) self._scroll_offset_y=math.max(0,self._scroll_offset_y+dy) end
function scroll:initState() self._max_scroll_offset_y=2000 end
function scroll:_updateScrollBars() self.bars_updated=true end
local content={dimen={y=0},_stream_row_stride=100,getSize=function() return {h=600} end}
local screen={_ctx_cache=ctx,_body_scroll=scroll,_current_page=1,
 _book_mod_slots={flat_library={content=content}},
 _isModOnVisiblePage=function() return true end}
local refreshes=0
function screen:_refresh(keep)
 assert(keep,"reuse cached files when loading more rows")
 refreshes=refreshes+1;scroll._scroll_offset_y=0
end
Stream.attach(scroll,screen)
scroll:_scrollBy(0,250)
assert(#tasks==1 and refreshes==0,"load only after gesture dispatch")
scroll:_scrollBy(0,10)
assert(#tasks==1,"coalesce overlapping scroll events")
table.remove(tasks,1)()
assert(refreshes==1 and scroll._scroll_offset_y==260 and scroll.bars_updated,
 "anchor survives a reset during refresh")
-- Move into the body of a full window: trimming three rows adjusts the
-- offset by exactly their height, leaving the same visible books.
local state=ctx._library_streams.flat_library
state.rows=12;state.first=0
scroll._scroll_offset_y=800
content.dimen.y=-800;content.getSize=function() return {h=1200} end
scroll:_scrollBy(0,100)
table.remove(tasks,1)()
assert(scroll._scroll_offset_y==600 and state.first==3)
-- Returning to a preceding window is also anchored.
content.dimen.y=-600
scroll:_scrollBy(0,-550)
table.remove(tasks,1)()
assert(scroll._scroll_offset_y==350 and state.first==0)
-- Navigation cancels a queued load before it can reset another page.
content.dimen.y=-350
scroll:_scrollBy(0,600)
assert(#tasks==1)
screen._current_page=2
local n=refreshes
table.remove(tasks,1)()
assert(refreshes==n and not screen._library_load_pending)
-- If the initial grid fits the viewport, an upward swipe still loads more.
local smallctx={};Stream.slice(smallctx,"flat_library",files,5)
local small={dimen={y=0,h=1000},_is_scrollable=false,
 _scrollBy=function() end,onScrollableSwipe=function() return false end}
local host={_ctx_cache=smallctx,_body_scroll=small,
 _book_mod_slots={flat_library={content={dimen={y=0},_stream_row_stride=50,
 getSize=function() return {h=300} end}}},_isModOnVisiblePage=function() return true end}
Stream.attach(small,host)
assert(small:onScrollableSwipe(nil,{direction="north"}) and #tasks==1)
table.remove(tasks,1) -- the deferred callback is covered by the cases above
''')
print('PASS: bounded lazy shelf, complete forward/backward traversal, anchor preservation and cancellation.')

# Exercise the actual grid builder with lightweight native layout contracts.
grid = (ROOT / 'engines/sui_book_grid.lua').read_text()
parts = [re.search(pattern, grid, re.S).group() for pattern in [
    r'local function _filterFileList\(.*?\nend\n',
    r'local function _resolveCurrentPage\(.*?\nend\n',
    r'function GridRenderer.build\(.*?\nend\n',
]]
lua.globals().grid_source = '\n'.join(parts)
lua.execute(r'''
local function factory(kind)
 return {new=function(_,o)
  o=o or {}
  function o:getSize()
   if self.dimen then return self.dimen end
   local w,h=0,0
   for _,child in ipairs(self) do
    local s=child:getSize()
    if kind=="vertical" then w=math.max(w,s.w);h=h+s.h
    else w=w+s.w;h=math.max(h,s.h) end
   end
   if kind=="span" then return {w=o.width,h=o.width} end
   return {w=w,h=h}
  end
  return o
 end}
end
VerticalGroup=factory("vertical");HorizontalGroup=factory("horizontal")
VerticalSpan=factory("span");HorizontalSpan=factory("span");InputContainer=factory("input")
Geom={new=function(_,o) return o end}
GridRenderer={getProgressStyle=function() return "none" end,
 resolveBadgeConfig=function() end,
 progressDrawsText=function() return false end,
 computeAutoFitCell=function(w,cols) return w/cols,10 end}
Config={getModuleScale=function() return 1 end,getThumbScale=function() return 1 end,
 getModuleScaleRaw=function() return 1 end,getThumbScaleRaw=function() return 1 end,
 resolveTextStyles=function() return {label={scale=1}} end}
SUIStyle={COLOR={text_primary=0},getTextFace=function() end,faceHeight=function() return 10 end}
Chrome={PLAIN_INK={}}
getSH=function() return {getDims=function() return {RECENT_H=100,RECENT_W=100} end} end
_migrateLabelTextScale=function() end;_BASE_RB_PCT_FS=10
UI={setFocusRows=function() end}
PageState={get=function() return 1,1 end,setPage=function() end,
 setCount=function(_,_,n) assert(n==1,"streaming shelf has no page arrows") end}
package.loaded["features/library/sui_hidden_books"]={isHidden=function() return false end}
assert(load(grid_source))()
local Stream=require("engines/sui_library_stream")
local all={};for i=1,200 do all[i]="book-"..i end
local calls=0
local opts={id="flat_library",scrollable=true,paged=false,grid_cols=5,
 getFileList=function() calls=calls+1;return all end,
 getCellHeight=function() return 100 end,
 renderCell=function(fp,w,h)
  return {getSize=function() return {w=w,h=h} end,fp=fp}
 end}
local ctx={pfx="test_"}
local first=GridRenderer.build(500,ctx,opts)
assert(#first._row_fps==30 and first._row_fps[1]=="book-1")
assert(first._stream_row_stride==105 and first[1][1][1].fp=="book-1")
Stream.advance(ctx,opts.id,1)
local more=GridRenderer.build(500,ctx,opts)
assert(#more._row_fps==45 and more:getSize().h>first:getSize().h)
Stream.advance(ctx,opts.id,1);Stream.advance(ctx,opts.id,1)
local shifted=GridRenderer.build(500,ctx,opts)
assert(#shifted._row_fps==60 and shifted._row_fps[1]=="book-16")
assert(shifted[1][1][1].fp=="book-16","cell identity follows the visible window")
assert(calls==1,"loading rows reuses the existing file list")
''')
print('PASS: shipped grid builder loads the correct cells, expands height, caps covers and reuses cached files.')
