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

    out["Accept-Encoding"] = nil
    return out
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

    return {
        status = res.status,
        headers = res.headers or {},
        body = res.body or "",
    }
end

return _M
