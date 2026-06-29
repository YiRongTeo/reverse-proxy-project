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

local BINARY_EXTENSIONS = {
    png = true,
    jpg = true,
    jpeg = true,
    gif = true,
    webp = true,
    ico = true,
    bmp = true,
    woff = true,
    woff2 = true,
    ttf = true,
    otf = true,
    eot = true,
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

    out["Accept-Encoding"] = "identity"
    out["Connection"] = "close"
    return out
end

local function get_header(headers, name)
    if not headers then
        return nil
    end

    return headers[name] or headers[name:lower()] or headers[name:upper()]
end

local function is_binary_asset(content_type, uri)
    if content_type and content_type ~= "" then
        local ct = content_type:lower()
        if ct:find("^image/", 1)
            or ct:find("^font/", 1)
            or ct:find("font%-woff", 1)
            or ct:find("application/vnd%.ms%-fontobject", 1)
            or ct:find("^application/octet%-stream", 1) then
            return true
        end
    end

    uri = uri or ""
    local extension = uri:match("%.([^./?]+)$")
    if extension then
        return BINARY_EXTENSIONS[extension:lower()] == true
    end

    return false
end

local function is_text_like(content_type)
    if not content_type or content_type == "" then
        return false
    end

    local ct = content_type:lower()
    return ct:find("text/html", 1, true)
        or ct:find("application/javascript", 1, true)
        or ct:find("text/javascript", 1, true)
        or ct:find("text/css", 1, true)
        or ct:find("application/json", 1, true)
        or ct:find("text/plain", 1, true)
        or ct:find("text/xml", 1, true)
        or ct:find("application/xml", 1, true)
        or ct:find("image/svg+xml", 1, true)
end

local function decode_body(body, headers, uri)
    local content_type = get_header(headers, "Content-Type")
    local encoding = get_header(headers, "Content-Encoding")
    if encoding then
        encoding = encoding:lower():match("^[%w%-]+")
    end

    if encoding == "br" then
        return nil, "unsupported Content-Encoding: br"
    end

    -- Only decompress when the upstream explicitly says so.
    if encoding == "gzip" then
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

    -- Binary assets (png, woff, etc.) are not compressed text — pass through as-is.
    if is_binary_asset(content_type, uri) then
        return body
    end

    -- Some HTML/JS/CSS devices send gzip without a Content-Encoding header.
    if is_text_like(content_type) and gzip.is_gzip(body) then
        local plain, err = gzip.inflate_gzip(body)
        if plain then
            ngx.log(ngx.INFO, "upstream inferred gzip for text asset bytes=", #body, "->", #plain)
            return plain
        end
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
        keepalive = false,
    })

    if not res then
        return nil, "upstream request failed: " .. (err or "unknown")
    end

    local headers = res.headers or {}
    local body, decode_err = decode_body(res.body or "", headers, opts.uri)
    if not body then
        return nil, decode_err
    end

    headers["Content-Encoding"] = nil
    headers["content-encoding"] = nil
    headers["Connection"] = nil
    headers["connection"] = nil

    return {
        status = res.status,
        headers = headers,
        body = body,
    }
end

return _M
