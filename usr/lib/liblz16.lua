local lz = require "lzss"
local buffer = require "buffer"

local lz16 = {}

local function readBuffer(fi)
    local stream = {}
    if fi:read(4) ~= "lz16" then return false, "not an lz16 archive" end
    function stream.read()
        local len = string.unpack(">I2", fi:read(2) or "\0\0")
        if len < 1 then return nil end
        if os.sleep then
            os.sleep(0)
        else
            coroutine.yield()
        end
        return lz.decompress(fi:read(len))
    end
    function stream.close() fi:close() end
    return buffer.new("rb", stream)
end

local function writeBuffer(fo)
    local stream = {}
    function stream:write(data)
        local cblock = lz.compress(data)
        fo:write(string.pack(">I2", cblock:len()) .. cblock)
        return cblock:len() + 2
    end
    function stream.close() fo:close() end
    fo:write("lz16") -- write header
    return buffer.new("wb", stream)
end

function lz16.buffer(stream) -- table -- table -- Wrap a stream to read or write LZ16.
    if stream.mode.w then return writeBuffer(stream) end
    return readBuffer(stream)
end

function lz16.open(fname, mode) -- string string -- table -- Open file *fname* to read or write LZ16-compressed data depending on *mode*
    local f = io.open(fname, mode)
    if not f then return false end
    f.mode.b = true
    return lz16.buffer(f)
end

return lz16
