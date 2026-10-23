-- Files in the LZ4 frame format, so the standard lz4 tool reads and writes them too.
--
-- Written: the frame header for independent blocks of up to 64 KB with no checksums, each block's
-- 32-bit little-endian size (high bit set when it is stored uncompressed), its data, and a zero
-- size to end. Read: also frames with a content size or checksums (skipped, not verified).
local lz4 = require('lz4')
local buffer = require('buffer')

local M = {}
local MAGIC, HEADER = '\4\34\77\24', '\4\34\77\24\96\64\130'   -- independent 64 KB blocks
local RAW = 0x80000000

local ok, computer = pcall(require, 'computer')
local clock = ok and computer.uptime or os.clock
-- Reading a block holds about three times its size, so by default a block is a sixteenth of the
-- machine's memory: 64 KB from one tier 3.5 stick, 12 KB on a single tier 1.
local DEFAULT = ok and math.max(4096, math.min(65536, computer.totalMemory() // 16)) or 65536
local resumed = clock()
-- OpenComputers stops a program that runs about five seconds without yielding.
local function breathe()
  if os.sleep and clock() - resumed > 1 then os.sleep(0); resumed = clock() end
end

local function exactly(file, n, what)
  local parts, left = {}, n
  while left > 0 do
    local part, why = file:read(left)
    if not part or part == '' then error(why or 'Truncated LZ4 ' .. what, 0) end
    parts[#parts + 1], left = part, left - #part
  end
  return table.concat(parts)
end

local function reader(file)
  local magic, why = file:read(4)
  if magic ~= MAGIC then return false, why or 'not an LZ4 frame' end
  local flags = string.byte(exactly(file, 2, 'frame header'))   -- then the block size byte
  if flags >> 6 ~= 1 then return false, 'unsupported LZ4 frame version' end
  if flags & 32 == 0 then return false, 'LZ4 frames of linked blocks are not supported' end
  if flags & 1 ~= 0 then return false, 'LZ4 frames with a dictionary are not supported' end
  exactly(file, (flags & 8 ~= 0 and 8 or 0) + 1, 'frame header')   -- content size, header checksum
  local stream, ended = {}, false
  function stream:read()
    if ended then return nil end
    local size = string.unpack('<I4', exactly(file, 4, 'block size'))
    if size == 0 then
      ended = true
      if flags & 4 ~= 0 then exactly(file, 4, 'content checksum') end
      return nil
    end
    local data = exactly(file, size & ~RAW, 'block')
    if flags & 16 ~= 0 then exactly(file, 4, 'block checksum') end
    breathe()
    if size & RAW ~= 0 then return data end
    return lz4.decompress(data)
  end
  function stream:close() return file:close() end
  return buffer.new('rb', stream)
end

local function writer(file, block)
  assert(block >= 1 and block <= 65536, 'LZ4 block size must be 1..65536')
  local wrote, why = file:write(HEADER)
  if not wrote then return false, why or 'Unable to write LZ4 frame header' end
  local stream, pending = {}, ''
  local function put(data)
    local packed, size = lz4.compress(data), nil
    if #packed < #data then size = #packed else packed, size = data, #data | RAW end
    local done, putWhy = file:write(string.pack('<I4', size) .. packed)
    if not done then error(putWhy or 'Unable to write LZ4 block', 0) end
    breathe()
  end
  function stream:write(data)
    pending = pending .. data
    while #pending >= block do
      put(pending:sub(1, block)); pending = pending:sub(block + 1)
    end
    return true
  end
  -- The last block and the end mark are written here, so a failed write surfaces from close; the
  -- file closes either way.
  function stream:close()
    local done, putWhy = pcall(function()
      if #pending > 0 then put(pending) end
      local ended, endWhy = file:write('\0\0\0\0')
      if not ended then error(endWhy or 'Unable to write LZ4 end mark', 0) end
    end)
    pending = ''
    local closed, closeWhy = file:close()
    if not done then error(putWhy, 0) end
    return closed, closeWhy
  end
  return buffer.new('wb', stream)
end

function M.buffer(stream, block) -- table [number] -- table -- Wrap an open binary stream to read or write an LZ4 frame; *block* bytes per block written.
  if stream.mode.w then return writer(stream, block or DEFAULT) end
  return reader(stream)
end

function M.open(path, mode, block) -- string string [number] -- table -- Open *path* to read or write an LZ4 frame per *mode*; *block* bytes per block written.
  local file, why = io.open(path, mode)
  if not file then return false, why end
  file.mode.b = true
  local done, stream, streamWhy = pcall(M.buffer, file, block)
  if done and stream then return stream end
  pcall(file.close, file)
  return false, done and streamWhy or stream
end

return M
