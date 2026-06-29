local gzip = require "lib.gzip"
local http = require "resty.http"

local _M = {}

local DEFAULT_TIMEOUT = tonumber(os.getenv("UPSTREAM_TIMEOUT_MS")) or 300000

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

-- Conditional cache headers cause upstream 304 responses with no body.
local CONDITIONAL = {
    ["if-none-match"] = true,
    ["if-modified-since"] = true,
    ["if-match"] = true,
    ["if-unmodified-since"] = true,
    ["if-range"] = true,
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

local function normalize_headers(headers, opts)
    opts = opts or {}
    local out = {}

    for key, value in pairs(headers or {}) do
        local lower = key:lower()
        if not HOP_BY_HOP[lower] and not CONDITIONAL[lower] then
            if type(value) == "table" then
                out[key] = table.concat(value, ", ")
            else
                out[key] = value
            end
        end
    end

    out["Accept-Encoding"] = "identity"
    out["Connection"] = "close"
    out["Cache-Control"] = "no-cache, no-store"
    out["Pragma"] = "no-cache"

    if opts.force_fresh then
        out["If-None-Match"] = nil
        out["If-Modified-Since"] = nil
    end

    return out
end

local function get_header(headers, name)
    if not headers then
        return nil
    end

    return headers[name] or headers[name:lower()] or headers[name:upper()]
end

local function looks_binary(data)
    if not data or #data < 8 then
        return false
    end

    if gzip.is_gzip(data) then
        return true
    end

    local sample = math.min(#data, 256)
    local control = 0
    for i = 1, sample do
        local byte = data:byte(i)
        if byte < 9 or (byte > 13 and byte < 32) then
            control = control + 1
        end
    end

    return control > (sample * 0.1)
end

local function decode_body(body, headers)
    local encoding = get_header(headers, "Content-Encoding")
    if encoding then
        encoding = encoding:lower():match("^[%w%-]+")
    end

    if encoding == "br" then
        return nil, "unsupported Content-Encoding: br"
    end

    if encoding == "gzip" or gzip.is_gzip(body) then
        local plain, err = gzip.inflate_gzip(body)
        if not plain then
            return nil, err or "gzip decompression failed"
        end

        ngx.log(ngx.INFO, "upstream gzip decompressed bytes=", #body, "->", #plain)
        return plain
    end

    if encoding == "deflate" or encoding == "x-deflate" then
        local plain, err = gzip.inflate_deflate(body)
        if not plain then
            return nil, err or "deflate decompression failed"
        end

        ngx.log(ngx.INFO, "upstream deflate decompressed bytes=", #body, "->", #plain)
        return plain
    end

    if looks_binary(body) then
        local plain, err = gzip.inflate_gzip(body)
        if plain then
            ngx.log(ngx.INFO, "upstream inferred gzip decompressed bytes=", #body, "->", #plain)
            return plain
        end

        plain, err = gzip.inflate_deflate(body)
        if plain then
            ngx.log(ngx.INFO, "upstream inferred deflate decompressed bytes=", #body, "->", #plain)
            return plain
        end

        return nil, "upstream body looks compressed but could not be decompressed"
    end

    return body
end

function _M.fetch(url, opts)
    opts = opts or {}

    if not url or url == "" then
        return nil, "missing upstream url"
    end

    url = append_query(url, opts.args)

    local function do_request(force_fresh)
        local httpc = http.new()
        httpc:set_timeout(opts.timeout or DEFAULT_TIMEOUT)

        return httpc:request_uri(url, {
            method = opts.method or "GET",
            headers = normalize_headers(opts.headers, { force_fresh = force_fresh }),
            body = opts.body,
            ssl_verify = false,
            keepalive = false,
        })
    end

    local res, err = do_request(false)
    if not res then
        return nil, "upstream request failed: " .. (err or "unknown")
    end

    local body = res.body or ""
    if (res.status == 304 or res.status == 204) and #body == 0 then
        ngx.log(ngx.INFO, "upstream returned ", res.status,
            " with empty body, retrying without cache validators")
        res, err = do_request(true)
        if not res then
            return nil, "upstream retry failed: " .. (err or "unknown")
        end
        body = res.body or ""
    end

    local headers = res.headers or {}
    local decoded, decode_err = decode_body(body, headers)
    if not decoded then
        return nil, decode_err
    end

    headers["Content-Encoding"] = nil
    headers["content-encoding"] = nil
    headers["Connection"] = nil
    headers["connection"] = nil
    headers["ETag"] = nil
    headers["etag"] = nil
    headers["Last-Modified"] = nil
    headers["last-modified"] = nil

    return {
        status = res.status,
        headers = headers,
        body = decoded,
    }
end

return _M
