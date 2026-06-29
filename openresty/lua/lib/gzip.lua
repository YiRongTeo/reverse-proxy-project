local ffi = require "ffi"

local _M = {}

ffi.cdef[[
typedef struct z_stream_s {
    const char *next_in;
    unsigned int avail_in;
    unsigned long total_in;
    char *next_out;
    unsigned int avail_out;
    unsigned long total_out;
    const char *msg;
    void *state;
    void *zalloc;
    void *zfree;
    void *opaque;
    int data_type;
    unsigned long adler;
    unsigned long reserved;
} z_stream;

const char *zlibVersion(void);
int inflateInit2_(z_stream *strm, int windowBits, const char *version, int stream_size);
int inflate(z_stream *strm, int flush);
int inflateEnd(z_stream *strm);
]]

local zlib = ffi.load("z")
local ZLIB_VERSION = ffi.string(zlib.zlibVersion())
local STREAM_SIZE = ffi.sizeof("z_stream")

local Z_OK = 0
local Z_STREAM_END = 1
local Z_BUF_ERROR = -5
local Z_NO_FLUSH = 0
local GZIP_WINDOW_BITS = 15 + 16
local DEFLATE_WINDOW_BITS = -15
local CHUNK_SIZE = 65536

function _M.is_gzip(data)
    return type(data) == "string"
        and #data >= 2
        and data:byte(1) == 0x1f
        and data:byte(2) == 0x8b
end

local function inflate_with_window(data, window_bits)
    local stream = ffi.new("z_stream")
    local rc = zlib.inflateInit2_(stream, window_bits, ZLIB_VERSION, STREAM_SIZE)
    if rc ~= Z_OK then
        return nil, "inflateInit2 failed: " .. rc
    end

    local in_buf = ffi.new("char[?]", #data)
    ffi.copy(in_buf, data, #data)

    stream.next_in = in_buf
    stream.avail_in = #data

    local chunks = {}
    local out_buf = ffi.new("char[?]", CHUNK_SIZE)

    repeat
        stream.next_out = out_buf
        stream.avail_out = CHUNK_SIZE

        rc = zlib.inflate(stream, Z_NO_FLUSH)

        local produced = CHUNK_SIZE - stream.avail_out
        if produced > 0 then
            chunks[#chunks + 1] = ffi.string(out_buf, produced)
        end
    until rc == Z_STREAM_END or (rc ~= Z_OK and rc ~= Z_BUF_ERROR)

    zlib.inflateEnd(stream)

    if rc ~= Z_STREAM_END then
        return nil, "inflate failed: " .. rc
    end

    return table.concat(chunks)
end

function _M.inflate_gzip(data)
    if not data or #data == 0 then
        return data
    end

    return inflate_with_window(data, GZIP_WINDOW_BITS)
end

function _M.inflate_deflate(data)
    if not data or #data == 0 then
        return data
    end

    return inflate_with_window(data, DEFLATE_WINDOW_BITS)
end

function _M.inflate(data)
    return _M.inflate_gzip(data)
end

return _M
