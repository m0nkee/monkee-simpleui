-- A bounded row window keeps long shelves cheap on older Kindles.
local Stream = { INITIAL_ROWS = 6, CHUNK_ROWS = 3, MAX_ROWS = 12 }

function Stream.state(ctx, id, cols)
    ctx._library_streams = ctx._library_streams or {}
    local state = ctx._library_streams[id]
    if not state or state.cols ~= cols then
        state = { cols = cols, first = 0, rows = Stream.INITIAL_ROWS, total = 0 }
        ctx._library_streams[id] = state
    end
    return state
end

function Stream.slice(ctx, id, files, cols)
    local state = Stream.state(ctx, id, cols)
    if state.files ~= files then
        local same = state.files and #state.files == #files
        if same then
            for i, file in ipairs(files) do
                if state.files[i] ~= file then same = false; break end
            end
        end
        if not same then state.first, state.rows = 0, Stream.INITIAL_ROWS end
        state.files = files
    end
    state.total = math.ceil(#files / cols)
    state.rows = math.max(1, math.min(state.rows, state.total))
    local visible = {}
    for i = state.first * cols + 1, math.min((state.first + state.rows) * cols, #files) do
        visible[#visible + 1] = files[i]
    end
    return visible, state.rows
end

-- Returns the row displacement needed to keep the same book under the eye.
function Stream.advance(ctx, id, direction)
    local state = ctx._library_streams and ctx._library_streams[id]
    if not state then return nil end
    local old_first = state.first
    if direction > 0 then
        local extra = math.min(Stream.CHUNK_ROWS, state.total - state.first - state.rows)
        if extra <= 0 then return nil end
        state.rows = state.rows + extra
        if state.rows > Stream.MAX_ROWS then
            state.first = state.first + state.rows - Stream.MAX_ROWS
            state.rows = Stream.MAX_ROWS
        end
    else
        if state.first == 0 then return nil end
        state.first = math.max(0, state.first - Stream.CHUNK_ROWS)
    end
    return old_first - state.first
end

function Stream.onScroll(screen, scroll, old_y, dy)
    if dy == 0 or screen._library_load_pending then return end
    local ctx = screen._ctx_cache
    if not ctx then return end
    local y = scroll._scroll_offset_y or 0
    for id, slot in pairs(screen._book_mod_slots or {}) do
        local content = slot.content
        if content and content._stream_row_stride and content.dimen
                and screen:_isModOnVisiblePage(id) then
            local stride = content._stream_row_stride
            local top = content.dimen.y - scroll.dimen.y + old_y
            local bottom = top + content:getSize().h
            local near_edge = dy > 0 and y + scroll.dimen.h >= bottom - stride
                or dy < 0 and y <= top + stride
            if near_edge then
                local shift = Stream.advance(ctx, id, dy > 0 and 1 or -1)
                if shift ~= nil then
                    screen._library_load_pending = true
                    local page = screen._current_page
                    -- Rebuild after gesture dispatch, preserving the visible anchor.
                    require("ui/uimanager"):nextTick(function()
                        screen._library_load_pending = nil
                        if screen._body_scroll ~= scroll or screen._ctx_cache ~= ctx
                                or screen._current_page ~= page then return end
                        local anchor_y = scroll._scroll_offset_y or y
                        screen:_refresh(true)
                        scroll:initState()
                        scroll._scroll_offset_y = math.max(0, math.min(
                            anchor_y + shift * stride, scroll._max_scroll_offset_y))
                        scroll:_updateScrollBars()
                    end)
                    return
                end
            end
        end
    end
end

function Stream.attach(scroll, screen)
    local original = scroll._scrollBy
    function scroll:_scrollBy(dx, dy, ...)
        local old_y = self._scroll_offset_y or 0
        original(self, dx, dy, ...)
        Stream.onScroll(screen, self, old_y, dy)
    end
    local swipe = scroll.onScrollableSwipe
    function scroll:onScrollableSwipe(args, ges)
        local handled = swipe(self, args, ges)
        -- A small grid may fit the viewport while more rows remain unloaded.
        if not handled and ges.direction == "north" and self._is_scrollable == false then
            if ges.pos and not ges.pos:intersectWith(self.dimen) then return false end
            Stream.onScroll(screen, self, self._scroll_offset_y or 0, 1)
            return screen._library_load_pending == true
        end
        return handled
    end
end

return Stream
