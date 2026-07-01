local _M = {}

local DEFAULT_ALLOW_HEADERS = table.concat({
    "Authorization",
    "Content-Type",
    "X-Requested-With",
    "Accept",
    "Origin",
    "X-Session-Id",
}, ", ")

local DEFAULT_ALLOW_METHODS = "GET, POST, PUT, PATCH, DELETE, OPTIONS"

function _M.get_origin(opts)
    local origin = ngx.var.http_origin
    if origin and origin ~= "" then
        return origin
    end

    if opts and opts.allow_credentials == false then
        return "*"
    end

    return ngx.var.http_referer or "*"
end

function _M.is_preflight()
    return ngx.req.get_method() == "OPTIONS"
        and ngx.var.http_access_control_request_method ~= nil
end

function _M.apply_response_headers(opts)
    opts = opts or {}

    local origin = opts.origin or _M.get_origin(opts)
    local allow_credentials = opts.allow_credentials
    if allow_credentials == nil then
        allow_credentials = true
    end

    ngx.header["Access-Control-Allow-Origin"] = origin
    ngx.header["Access-Control-Allow-Methods"] = opts.allow_methods or DEFAULT_ALLOW_METHODS
    ngx.header["Access-Control-Allow-Headers"] = opts.allow_headers or DEFAULT_ALLOW_HEADERS
    ngx.header["Access-Control-Expose-Headers"] = opts.expose_headers or "Content-Length, Content-Type, Location"
    ngx.header["Access-Control-Max-Age"] = tostring(opts.max_age or 86400)

    if allow_credentials then
        ngx.header["Access-Control-Allow-Credentials"] = "true"
    end

    if opts.allow_private_network then
        ngx.header["Access-Control-Allow-Private-Network"] = "true"
    end
end

function _M.handle_preflight(opts)
    if not _M.is_preflight() then
        return false
    end

    _M.apply_response_headers(opts)
    return ngx.exit(ngx.HTTP_NO_CONTENT)
end

return _M
