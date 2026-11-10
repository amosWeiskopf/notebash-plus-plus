-- indexes where each record starts, for a file of any size. jump to row
-- 9,000,000 of a 5 gb file without reading the 8,999,999 rows before it. i
-- want to edit the damn file before i die. a record is a line, or a csv row
-- (which can span lines when a quoted field contains a line break).
--
-- a background thread reads 16 mb at a time. the index keeps the byte offset
-- of every 512th record (a checkpoint). reading record n takes one seek to
-- the checkpoint before it, then at most 511 records scanned. 12 million rows
-- need 23,000 checkpoints, about 200 kb. basically my retirement plan has
-- more overhead. the view shows the file's top at once; the rest becomes
-- reachable as counting proceeds, about 1 gb per second.

local file_index = {}
local uv = vim.uv

file_index.CHECKPOINT_INTERVAL = 512
-- module fields, so the tests can shrink them and watch the machinery sweat.
file_index.chunk_bytes = 16 * 1024 * 1024
-- records longer than this are cut for display. i have limits (finally). the
-- index saves each such record's end, so the reader can step over it without
-- reading the whole damn thing.
file_index.LONGEST_SHOWN_RECORD = 1024 * 1024

local NEWLINE_BYTE = 10
local CARRIAGE_RETURN_BYTE = 13
local QUOTE_BYTE = 34

-- counts records in one file chunk, in a libuv worker thread. plain lua &
-- arguments only: no upvalues, no vim api. a small mercy, being away from
-- vim. a quote opens a quoted field only at a field's start: after a
-- delimiter, a line break, or at the start of the file. a stray inch sign in
-- 5" screen must not swallow the remaining file. absolutely enough shit gets
-- swallowed in the name of compatibility already. inside a quoted field, two
-- quotes mean an escaped quote. read one extra byte so a quote at the chunk's
-- last byte can check whether the next byte is also a quote. libuv gives a
-- worker only a few arguments, so pack the numbers into one comma separated
-- string. basically a suitcase for a very shitty holiday.
local function count_records_in_chunk(path, packed_numbers)
    local numbers = {}
    for number in packed_numbers:gmatch('%-?%d+') do
        numbers[#numbers + 1] = tonumber(number)
    end
    local chunk_offset, chunk_length, inside_quotes_flag, previous_byte = numbers[1], numbers[2], numbers[3], numbers[4]
    local records_before, checkpoint_interval, delimiter_byte = numbers[5], numbers[6], numbers[7]
    local quote_aware_flag, current_record_start, longest_record = numbers[8], numbers[9], numbers[10]
    local file = io.open(path, 'rb')
    if not file then
        return -1
    end
    file:seek('set', chunk_offset)
    local data = file:read(chunk_length + 1) or ''
    file:close()
    local data_length = math.min(#data, chunk_length)
    local find, byte = string.find, string.byte
    local checkpoints, long_records = {}, {}
    local record_count = records_before
    local inside_quotes = inside_quotes_flag == 1
    local quote_aware = quote_aware_flag == 1
    local position = 1
    local function end_record_at(newline_position)
        local absolute_end = chunk_offset + newline_position - 1
        if absolute_end - current_record_start > longest_record then
            long_records[#long_records + 1] = current_record_start .. ':' .. absolute_end
        end
        record_count = record_count + 1
        current_record_start = absolute_end + 1
        if record_count % checkpoint_interval == 0 then
            checkpoints[#checkpoints + 1] = current_record_start
        end
    end
    if not quote_aware then
        while true do
            local newline_position = find(data, '\n', position, true)
            if not newline_position or newline_position > data_length then
                break
            end
            end_record_at(newline_position)
            position = newline_position + 1
        end
        position = data_length + 1
    else
        -- the next quote & the next line break are both remembered until
        -- passed. searching for the line break again after every quote made an
        -- 18 mb file of quotes take seconds per chunk. quadratic time, the
        -- only thing in my life that grows reliably.
        local next_quote = find(data, '"', position, true)
        local next_newline = find(data, '\n', position, true)
        while position <= data_length do
            if inside_quotes then
                if not next_quote or next_quote > data_length then
                    position = data_length + 1
                    break
                end
                if byte(data, next_quote + 1) == 34 then
                    position = next_quote + 2
                else
                    inside_quotes = false
                    position = next_quote + 1
                end
                next_quote = find(data, '"', position, true)
            else
                if next_newline and next_newline < position then
                    next_newline = find(data, '\n', position, true)
                end
                local newline_position = next_newline
                if newline_position and newline_position > data_length then
                    newline_position = nil
                end
                if next_quote and next_quote <= data_length and (not newline_position or next_quote < newline_position) then
                    local byte_before = next_quote > 1 and byte(data, next_quote - 1) or previous_byte
                    if byte_before == delimiter_byte or byte_before == 10 or byte_before == 13 or byte_before == -1 then
                        inside_quotes = true
                    end
                    position = next_quote + 1
                    next_quote = find(data, '"', position, true)
                elseif newline_position then
                    end_record_at(newline_position)
                    position = newline_position + 1
                else
                    position = data_length + 1
                end
            end
        end
    end
    local consumed = position - 1
    local last_byte = consumed > 0 and byte(data, consumed) or previous_byte
    -- the worker's lua state lives between chunks; free the 16 mb chunk now.
    -- i've wasted enough of my life waiting for this shit to collect itself.
    data = nil
    collectgarbage()
    return consumed,
        record_count - records_before,
        table.concat(checkpoints, ','),
        inside_quotes and 1 or 0,
        last_byte,
        current_record_start,
        table.concat(long_records, ',')
end

local Index = {}
Index.__index = Index

-- open an index for `path`. options.quote_aware handles csv quoted line
-- breaks; options.delimiter is the field separator byte for that quote rule.
-- options.on_progress is scheduled after each chunk and at the end. i want
-- evidence that something in my life is progressing.
---@return table? index, string? problem
function file_index.open(path, options)
    options = options or {}
    local stat = uv.fs_stat(path)
    if not stat then
        return nil, 'cannot read ' .. path
    end
    local descriptor, open_error = uv.fs_open(path, 'r', 0)
    if not descriptor then
        return nil, open_error
    end
    local index = setmetatable({
        path = path,
        size = stat.size,
        -- text survives json in session.json without rounding. numbers betray
        -- us.
        modification_time = ('%d.%09d'):format(stat.mtime.sec, stat.mtime.nsec),
        descriptor = descriptor,
        quote_aware = options.quote_aware == true,
        delimiter_byte = (options.delimiter or ','):byte(),
        on_progress = options.on_progress,
        -- checkpoints[k]: byte offset of record (k - 1) * interval.
        checkpoints = { 0 },
        long_records = {},
        record_count = 0,
        indexed_bytes = 0,
        complete = stat.size == 0,
        stopped = false,
        block_cache = {},
        block_cache_order = {},
        block_cache_bytes = 0,
    }, Index)
    return index
end

-- count in the background, one chunk at a time, each in a worker thread. the
-- main loop only appends results. even this bastard gets a lighter job.
function Index:start()
    if self.complete then
        self:finish()
        return
    end
    local inside_quotes, previous_byte, current_record_start = 0, -1, 0
    local work
    local function queue_next_chunk()
        local length = math.min(file_index.chunk_bytes, self.size - self.indexed_bytes)
        local packed_numbers = table.concat({
            self.indexed_bytes,
            length,
            inside_quotes,
            previous_byte,
            self.record_count,
            file_index.CHECKPOINT_INTERVAL,
            self.delimiter_byte,
            self.quote_aware and 1 or 0,
            current_record_start,
            file_index.LONGEST_SHOWN_RECORD,
        }, ',')
        work:queue(self.path, packed_numbers)
    end
    work = uv.new_work(count_records_in_chunk, function(consumed, found, checkpoint_text, quotes_after, last_byte, record_start, long_text)
        if self.stopped then
            return
        end
        if consumed == nil or consumed == -1 or consumed == 0 then
            self.failed = consumed ~= 0 and 'the file could not be read' or nil
            self:finish()
            return
        end
        for checkpoint in checkpoint_text:gmatch('%d+') do
            self.checkpoints[#self.checkpoints + 1] = tonumber(checkpoint)
        end
        for record_first, record_last in long_text:gmatch('(%d+):(%d+)') do
            self.long_records[tonumber(record_first)] = tonumber(record_last)
        end
        self.record_count = self.record_count + found
        self.indexed_bytes = self.indexed_bytes + consumed
        inside_quotes, previous_byte, current_record_start = quotes_after, last_byte, record_start
        self.last_record_start = record_start
        if self.indexed_bytes >= self.size then
            self:finish()
        else
            self:report_progress()
            queue_next_chunk()
        end
    end)
    queue_next_chunk()
end

-- if the file has no final line break, count its last record too. unfinished
-- things still count. i need this to be true.
function Index:finish()
    if self.size > 0 and (self.last_record_start or 0) < self.size then
        self.record_count = self.record_count + 1
        self.unterminated_last_record = true
        -- an unclosed quote can make the last record a gigabyte long without
        -- any line break for the thread to note it at. note it here. it's
        -- always the last one that goes on forever.
        local last_start = self.last_record_start or 0
        if self.size - last_start > file_index.LONGEST_SHOWN_RECORD then
            self.long_records[last_start] = self.size
        end
    end
    if self.size > 0 and self.record_count == 0 then
        self.record_count = 1
    end
    self.indexed_bytes = self.size
    self.complete = true
    -- blocks read while counting may stop short of rows counted since. throw
    -- them all out; the next read starts clean. a fresh start, which is more
    -- than the rest of us get.
    self.block_cache, self.block_cache_order, self.block_cache_bytes = {}, {}, 0
    self:report_progress()
end

function Index:report_progress()
    if self.on_progress then
        vim.schedule(function()
            if not self.stopped then
                self.on_progress(self)
            end
        end)
    end
end

-- 0 to 100 for the status bar. hope, measured.
function Index:percent_done()
    if self.size == 0 then
        return 100
    end
    return math.floor(self.indexed_bytes * 100 / self.size)
end

-- readable now: everything counted so far. hope has a cutoff.
function Index:known_record_count()
    return self.record_count
end

function Index:stop()
    self.stopped = true
    if self.descriptor then
        uv.fs_close(self.descriptor)
        self.descriptor = nil
    end
end

-- true if another program changed the file since opening. trust is dead.
function Index:changed_on_disk()
    local stat = uv.fs_stat(self.path)
    if not stat then
        return true
    end
    return stat.size ~= self.size or ('%d.%09d'):format(stat.mtime.sec, stat.mtime.nsec) ~= self.modification_time
end

function Index:read_bytes(offset, length)
    if not self.descriptor or length <= 0 then
        return ''
    end
    return uv.fs_read(self.descriptor, length, offset) or ''
end

-- one checkpoint block's records as { first, last } byte ranges, 0-based,
-- inclusive of content, excluding the line break. scan from the checkpoint
-- using the thread's quote rule. i'd love fewer rules in my life; apparently
-- even punctuation needs a damn custody agreement.
local function scan_block(self, block_number)
    local block_start = self.checkpoints[block_number + 1]
    if not block_start then
        return {}
    end
    local first_record = block_number * file_index.CHECKPOINT_INTERVAL
    local wanted = math.min(file_index.CHECKPOINT_INTERVAL, self.record_count - first_record)
    if wanted <= 0 then
        return {}
    end
    local ranges = {}
    local offset = block_start
    local inside_quotes = false
    local previous_byte = -1
    local record_start = block_start
    local read_size = 256 * 1024
    while #ranges < wanted and offset < self.size do
        -- skip records longer than the display limit using the end saved by
        -- the thread. some shit you can actually step over.
        local long_record_end = offset == record_start and self.long_records[record_start]
        if long_record_end then
            ranges[#ranges + 1] = { first = record_start, last = long_record_end - 1, cut = true }
            offset = long_record_end + 1
            record_start = offset
            inside_quotes, previous_byte = false, NEWLINE_BYTE
        else
            local data = self:read_bytes(offset, read_size)
            if data == '' then
                break
            end
            local position = 1
            local data_length = #data
            -- find the next quote once & reuse it until passed: quote-free
            -- rows cost one search per row, rather than per byte. suffering
            -- needs a budget too.
            local next_quote = self.quote_aware and data:find('"', 1, true) or nil
            -- same deal for the next line break, or a row of 200,000 quotes
            -- searches the rest of the buffer 200,000 times.
            local next_newline = data:find('\n', 1, true)
            while position <= data_length and #ranges < wanted do
                if next_quote and next_quote < position then
                    next_quote = data:find('"', position, true)
                end
                if inside_quotes then
                    if not next_quote then
                        position = data_length + 1
                    elseif next_quote == data_length and offset + data_length < self.size then
                        -- escaped quote? can't tell yet. reread from here.
                        -- shit.
                        break
                    elseif data:byte(next_quote + 1) == QUOTE_BYTE then
                        position = next_quote + 2
                    else
                        inside_quotes = false
                        position = next_quote + 1
                    end
                else
                    if next_newline and next_newline < position then
                        next_newline = data:find('\n', position, true)
                    end
                    local newline_position = next_newline
                    if next_quote and (not newline_position or next_quote < newline_position) then
                        local byte_before = next_quote > 1 and data:byte(next_quote - 1) or previous_byte
                        if byte_before == self.delimiter_byte or byte_before == NEWLINE_BYTE or byte_before == CARRIAGE_RETURN_BYTE or byte_before == -1 then
                            inside_quotes = true
                        end
                        position = next_quote + 1
                    elseif newline_position then
                        local absolute_newline = offset + newline_position - 1
                        ranges[#ranges + 1] = { first = record_start, last = absolute_newline - 1 }
                        record_start = absolute_newline + 1
                        position = newline_position + 1
                        if self.long_records[record_start] then
                            break
                        end
                    else
                        position = data_length + 1
                    end
                end
            end
            local consumed = position - 1
            if consumed <= 0 then
                -- quote at the buffer's very end. read more. damn
                -- cliffhanger.
                read_size = read_size * 2
            else
                previous_byte = data:byte(consumed)
                offset = offset + consumed
            end
            -- a record past the display limit with no saved end only happens
            -- while counting is still running. basically the paperwork for
            -- this hell is late.
            if offset - record_start > file_index.LONGEST_SHOWN_RECORD * 2 then
                ranges[#ranges + 1] = { first = record_start, last = offset - 1, cut = true }
                break
            end
        end
    end
    -- last record, no final line break. even endings fail.
    if #ranges < wanted and record_start < self.size and offset >= self.size then
        ranges[#ranges + 1] = { first = record_start, last = self.size - 1 }
    end
    return ranges
end

local BLOCKS_KEPT = 48
-- the cache also stops at this many bytes of record text. 48 blocks of 512
-- one megabyte lines would otherwise be 24 gb, and my laptop has opinions.
file_index.block_cache_byte_limit = 64 * 1024 * 1024

-- rows the block holds once counting has reached all of it. fewer while
-- counting is still on the way. waiting for the rest is my default state.
local function rows_counted_in_block(self, block_number)
    return math.max(0, math.min(file_index.CHECKPOINT_INTERVAL, self.record_count - block_number * file_index.CHECKPOINT_INTERVAL))
end

local function forget_block(self, block_number)
    local cached = self.block_cache[block_number]
    if not cached then
        return
    end
    self.block_cache[block_number] = nil
    self.block_cache_bytes = self.block_cache_bytes - cached.byte_count
    for position, cached_number in ipairs(self.block_cache_order) do
        if cached_number == block_number then
            table.remove(self.block_cache_order, position)
            break
        end
    end
end

-- cache one block's raw record texts, without line breaks or trailing
-- carriage returns. length-cut records stop at the limit. i want boundaries
-- this reliable in the rest of my damn life. a block read while counting had
-- only reached part of it is good only until counting finds more of its rows;
-- then it is read again. keeping the short copy forever showed counted rows as
-- empty and sent their edits to the end of the file. i lost data that way
-- once. i lose everything else the normal way.
function Index:block(block_number)
    local rows_counted = rows_counted_in_block(self, block_number)
    local cached = self.block_cache[block_number]
    if cached and cached.rows_counted == rows_counted then
        return cached
    end
    forget_block(self, block_number)
    local ranges = scan_block(self, block_number)
    local records = { ranges = ranges, rows_counted = rows_counted, byte_count = 0, carriage_returns = {} }
    -- one read per run of ordinary records; length-cut records get separate
    -- reads up to the limit. even this shit has a class system.
    local run_start = 1
    while run_start <= #ranges do
        local range = ranges[run_start]
        if range.cut then
            records[run_start] = self:read_bytes(range.first, file_index.LONGEST_SHOWN_RECORD)
            run_start = run_start + 1
        else
            local run_end = run_start
            while ranges[run_end + 1] and not ranges[run_end + 1].cut do
                run_end = run_end + 1
            end
            local run_first_byte = range.first
            local run_text = self:read_bytes(run_first_byte, ranges[run_end].last - run_first_byte + 1)
            for position = run_start, run_end do
                records[position] = run_text:sub(ranges[position].first - run_first_byte + 1, ranges[position].last - run_first_byte + 1)
            end
            run_start = run_end + 1
        end
    end
    for position, text in ipairs(records) do
        if text:byte(-1) == CARRIAGE_RETURN_BYTE then
            records[position] = text:sub(1, -2)
            records.carriage_returns[position] = true
        end
        records.byte_count = records.byte_count + #text
    end
    self.block_cache[block_number] = records
    self.block_cache_bytes = self.block_cache_bytes + records.byte_count
    table.insert(self.block_cache_order, block_number)
    while #self.block_cache_order > 1 and (#self.block_cache_order > BLOCKS_KEPT or self.block_cache_bytes > file_index.block_cache_byte_limit) do
        forget_block(self, self.block_cache_order[1])
    end
    return records
end

-- raw text of `record_number` (0-based), true if cut for length, and true if
-- a carriage return was taken off its end. a small, honest mutilation.
---@return string?, boolean?, boolean?
function Index:record(record_number)
    if record_number < 0 or record_number >= self.record_count then
        return nil
    end
    local block_number = math.floor(record_number / file_index.CHECKPOINT_INTERVAL)
    local records = self:block(block_number)
    local position = record_number - block_number * file_index.CHECKPOINT_INTERVAL + 1
    local range = records.ranges[position]
    return records[position], range and range.cut, records.carriage_returns[position] == true
end

-- start byte offset of `record_number`; passing record_count gives file size.
-- finally an ending i can locate. a counted record the block cannot find is
-- an error, never the file size: the file size put an edited row 900 at the
-- end of the file. i'd rather crash than quietly rearrange somebody's life.
function Index:record_offset(record_number)
    if record_number >= self.record_count then
        return self.size
    end
    local interval = file_index.CHECKPOINT_INTERVAL
    -- the first record of a block is a checkpoint: no reading needed.
    if record_number % interval == 0 and self.checkpoints[record_number / interval + 1] then
        return self.checkpoints[record_number / interval + 1]
    end
    local block_number = math.floor(record_number / interval)
    local records = self:block(block_number)
    local range = records.ranges[record_number - block_number * interval + 1]
    if not range then
        error(('cannot find where row %d of %s starts'):format(record_number + 1, self.path), 0)
    end
    return range.first
end

-- true if the file this index read was changed where it stands (written to,
-- truncated or grown), seen through the descriptor opened at the start. a
-- file replaced by renaming another over it still has its old self behind
-- that descriptor. even files get to keep a past, apparently.
function Index:changed_in_place()
    if not self.descriptor then
        return true
    end
    local stat = uv.fs_fstat(self.descriptor)
    if not stat then
        return true
    end
    return stat.size ~= self.size or ('%d.%09d'):format(stat.mtime.sec, stat.mtime.nsec) ~= self.modification_time
end

-- record containing byte `offset`; indexing must have reached it. no
-- miracles.
function Index:record_at_offset(offset)
    local low, high = 1, #self.checkpoints
    while low < high do
        local middle = math.floor((low + high + 1) / 2)
        if self.checkpoints[middle] <= offset then
            low = middle
        else
            high = middle - 1
        end
    end
    local block_number = low - 1
    local records = self:block(block_number)
    for position, range in ipairs(records.ranges) do
        local next_range = records.ranges[position + 1]
        if offset >= range.first and (not next_range or offset < next_range.first) then
            return block_number * file_index.CHECKPOINT_INTERVAL + position - 1
        end
    end
    return math.min(self.record_count - 1, (block_number + 1) * file_index.CHECKPOINT_INTERVAL)
end

-- search file bytes [from, to) for `needle`. worker thread, like the counter;
-- plain lua only. leave neovim out of this particular misery.
local function search_chunk(path, from, to, needle, ignore_case_flag)
    local file = io.open(path, 'rb')
    if not file then
        return -1
    end
    local chunk_size = 16 * 1024 * 1024
    local overlap = #needle - 1
    local position = from
    while position < to do
        file:seek('set', position)
        local data = file:read(math.min(chunk_size + overlap, to - position + overlap))
        if not data or data == '' then
            break
        end
        if ignore_case_flag == 1 then
            data = data:lower()
        end
        local found = data:find(needle, 1, true)
        data = nil
        collectgarbage()
        if found then
            file:close()
            return position + found - 1
        end
        position = position + chunk_size
    end
    file:close()
    return -1
end

-- find the first byte offset at or after `from` containing `needle`, wrapping
-- once to the start. call on_found(offset), or on_found(nil) if absent.
-- search in a worker thread, 256 mb per step, so even a huge file never
-- freezes typing. i'd hate to interrupt whatever shit i'm writing. call the
-- returned function to cancel. one commitment i can get out of.
function Index:search(needle, from, ignore_case, on_found)
    if ignore_case then
        needle = needle:lower()
    end
    local step = 256 * 1024 * 1024
    local cancelled = false
    local passes = { { from, self.size }, { 0, math.min(from + #needle, self.size) } }
    local pass_number, position = 1, passes[1][1]
    local work
    local function next_step()
        local pass = passes[pass_number]
        if not pass then
            vim.schedule(function()
                on_found(nil)
            end)
            return
        end
        if position >= pass[2] then
            pass_number = pass_number + 1
            position = passes[pass_number] and passes[pass_number][1] or 0
            return next_step()
        end
        work:queue(self.path, position, math.min(pass[2], position + step), needle, ignore_case and 1 or 0)
    end
    work = uv.new_work(search_chunk, function(found_offset)
        if cancelled or self.stopped then
            return
        end
        if found_offset and found_offset >= 0 then
            vim.schedule(function()
                on_found(found_offset)
            end)
            return
        end
        position = position + step
        next_step()
    end)
    next_step()
    return function()
        cancelled = true
    end
end

return file_index
