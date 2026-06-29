local gzip = require "lib.gzip"
local http = require "resty.http"

local _M = {}

local DEFAULT_TIMEOUT = tonumber(os.getenv("UPSTREAM_TIMEOUT_MS")) or 300000

local REDIRECT_STATUSES = {
    [301] = true,
    [302] = true,
    [303] = true,
    [307] = true,
    [308] = true,
}

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

    if is_binary_asset(content_type, uri) then
        return body
    end

    if is_text_like(content_type) and gzip.is_gzip(body) then
        local plain, err = gzip.inflate_gzip(body)
        if plain then
            ngx.log(ngx.INFO, "upstream inferred gzip for text asset bytes=", #body, "->", #plain)
            return plain
        end
    end

    return body
end

local function merge_set_cookie(jar, headers)
    local set_cookie = headers["Set-Cookie"] or headers["set-cookie"]
    if not set_cookie then
        return
    end

    local cookies = set_cookie
    if type(cookies) ~= "table" then
        cookies = { cookies }
    end

    for _, cookie in ipairs(cookies) do
        local name, value = cookie:match("^%s*([^=]+)=([^;]*)")
        if name then
            jar[name] = value
        end
    end
end

local function cookie_header(jar)
    local parts = {}
    for name, value in pairs(jar) do
        parts[#parts + 1] = name .. "=" .. value
    end

    return table.concat(parts, "; ")
end

local function normalize_origin(url)
    if not url or url == "" then
        return ""
    end

    url = url:gsub("/+$", "")
    url = url:gsub("^https://([^:/]+):443", "https://%1")
    url = url:gsub("^http://([^:/]+):80", "http://%1")
    return url
end

local function redirect_path_key(url)
    local path = url:match("^https?://[^/]+(.*)$") or url
    if path == "" then
        path = "/"
    end
    return path
end

local function resolve_redirect_url(base_url, location, session_origin)
    if location:match("^https?://") then
        if session_origin and session_origin ~= "" then
            local path = location:match("^https?://[^/]+(.*)$") or "/"
            if path == "" then
                path = "/"
            end
            return normalize_origin(session_origin) .. path
        end
        return location
    end

    if location:sub(1, 1) == "/" then
        local origin = base_url:match("^(https?://[^/]+)")
        return origin .. location
    end

    local origin, path = base_url:match("^(https?://[^/]+)(/.*)$")
    if not origin then
        return base_url
    end

    local base_dir = path:match("^(.*/)[^/]*$") or "/"
    return origin .. base_dir .. location
end

local function should_follow_redirect(method, status)
    if method == "GET" then
        return true
    end

    -- Login forms and similar POST flows often end in a 302/303 to a GET page.
    return method == "POST" and (status == 302 or status == 303)
end

local function do_request(url, method, headers, body, timeout)
    local httpc = http.new()
    httpc:set_timeout(timeout or DEFAULT_TIMEOUT)

    return httpc:request_uri(url, {
        method = method,
        headers = headers,
        body = body,
        ssl_verify = false,
        keepalive = false,
    })
end

function _M.fetch(url, opts)
    opts = opts or {}

    if not url or url == "" then
        return nil, "missing upstream url"
    end

    local method = opts.method or "GET"
    local max_redirects = 0
    if opts.follow_redirects then
        max_redirects = opts.max_redirects or 5
    end

    local current_url = append_query(url, opts.args)
    local base_headers = normalize_headers(opts.headers)
    local cookie_jar = {}
    local body = opts.body
    local res
    local visited = {}
    local session_origin = opts.redirect_origin

    for hop = 0, max_redirects do
        local visit_key = session_origin and redirect_path_key(current_url) or current_url
        if visited[visit_key] then
            ngx.log(ngx.WARN, "upstream redirect loop at ", current_url,
                " key=", visit_key)
            break
        end
        visited[visit_key] = true

        local headers = {}
        for key, value in pairs(base_headers) do
            headers[key] = value
        end

        local cookie = cookie_header(cookie_jar)
        if cookie ~= "" then
            headers["Cookie"] = cookie
        end

        local err
        res, err = do_request(current_url, method, headers, body, opts.timeout)
        if not res then
            return nil, "upstream request failed: " .. (err or "unknown")
        end

        merge_set_cookie(cookie_jar, res.headers or {})

        local location = get_header(res.headers, "Location")
        if hop < max_redirects
            and REDIRECT_STATUSES[res.status]
            and location
            and should_follow_redirect(method, res.status) then
            current_url = resolve_redirect_url(current_url, location, session_origin)
            ngx.log(ngx.INFO, "upstream redirect hop=", hop + 1, " status=", res.status,
                " location=", location, " -> ", current_url)
            method = "GET"
            body = nil
        else
            break
        end
    end

    local headers = res.headers or {}
    local decoded, decode_err = decode_body(res.body or "", headers, opts.uri)
    if not decoded then
        return nil, decode_err
    end

    headers["Content-Encoding"] = nil
    headers["content-encoding"] = nil
    headers["Connection"] = nil
    headers["connection"] = nil

    return {
        status = res.status,
        headers = headers,
        body = decoded,
    }
end

return _M
