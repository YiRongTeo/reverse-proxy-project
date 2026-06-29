local gzip = require "lib.gzip"
local http = require "resty.http"

local _M = {}

local DEFAULT_TIMEOUT = tonumber(os.getenv("UPSTREAM_TIMEOUT_MS")) or 300000
local DEFAULT_KEEPALIVE = tonumber(os.getenv("UPSTREAM_KEEPALIVE_MS")) or 10000
local DEFAULT_POOL_SIZE = tonumber(os.getenv("UPSTREAM_POOL_SIZE")) or 100

local HOP_BY_HOP = {
    ["connection"] = true,
    ["keep-alive"] = true,
    ["proxy-authenticate"] = true,
    ["proxy-authorization"] = true,
    ["te"] = true,
    ["trailer"] = true,
    ["transfer-encoding"] = true,
    ["upgrade"] = true,
    ["accept-encoding"] = true,
    ["content-encoding"] = true,
}

local function append_query(url, args)
    if not args or args == "" then
        return url
    end

    if url:find("?", 1, true) then
        return url .. "&" .. args
    end

    return url .. "?" .. args
end

local function normalize_headers(headers)
    local out = {}

    for key, value in pairs(headers or {}) do
        local lower = key:lower()
        if not HOP_BY_HOP[lower] then
            if type(value) == "table" then
                out[key] = table.concat(value, ", ")
            else
                out[key] = value
            end
        end
    end

    -- Ask upstream for plain text; decompress below if it ignores this.
    out["Accept-Encoding"] = "identity"
    return out
end

local function get_header(headers, name)
    if not headers then
        return nil
    end

    return headers[name] or headers[name:lower()] or headers[name:upper()]
end

local function decode_body(body, headers)
    local encoding = get_header(headers, "Content-Encoding")
    if encoding then
        encoding = encoding:lower()
    end

    if encoding == "br" or encoding == "deflate" then
        return nil, "unsupported Content-Encoding: " .. encoding
    end

    if encoding == "gzip" or gzip.is_gzip(body) then
        local plain, err = gzip.inflate(body)
        if not plain then
            return nil, err or "gzip decompression failed"
        end

        ngx.log(ngx.INFO, "upstream gzip decompressed bytes=", #body, "->", #plain)
        return plain
    end

    return body
end

function _M.fetch(url, opts)
    opts = opts or {}

    if not url or url == "" then
        return nil, "missing upstream url"
    end

    url = append_query(url, opts.args)

    local httpc = http.new()
    httpc:set_timeout(opts.timeout or DEFAULT_TIMEOUT)

    local res, err = httpc:request_uri(url, {
        method = opts.method or "GET",
        headers = normalize_headers(opts.headers),
        body = opts.body,
        ssl_verify = false,
    })

    if not res then
        return nil, "upstream request failed: " .. (err or "unknown")
    end

    local ok, keepalive_err = httpc:set_keepalive(DEFAULT_KEEPALIVE, DEFAULT_POOL_SIZE)
    if not ok then
        ngx.log(ngx.WARN, "upstream keepalive failed: ", keepalive_err)
    end

    local headers = res.headers or {}
    local body, decode_err = decode_body(res.body or "", headers)
    if not body then
        return nil, decode_err
    end

    headers["Content-Encoding"] = nil
    headers["content-encoding"] = nil

    return {
        status = res.status,
        headers = headers,
        body = body,
    }
end

return _M
