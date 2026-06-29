local device_registry = require "lib.device_registry"
local html_rewrite = require "lib.html_rewrite"
local proxy_util = require "lib.proxy_util"

local device_name = ngx.ctx.junction_device or ngx.var.junction_device
local device = device_registry.get(device_name)
if not device then
    return proxy_util.deny(ngx.HTTP_NOT_FOUND, "unknown device junction")
end

local method = ngx.req.get_method()
if method == "POST" or method == "PUT" or method == "PATCH" or method == "DELETE" then
    ngx.req.read_body()
end

local method_map = {
    GET = ngx.HTTP_GET,
    HEAD = ngx.HTTP_HEAD,
    POST = ngx.HTTP_POST,
    PUT = ngx.HTTP_PUT,
    PATCH = ngx.HTTP_PATCH,
    DELETE = ngx.HTTP_DELETE,
}

local capture_method = method_map[method]
if not capture_method then
    return proxy_util.deny(ngx.HTTP_BAD_REQUEST, "unsupported method")
end

local capture_headers = ngx.req.get_headers()
capture_headers["Accept-Encoding"] = nil

for key, value in pairs(capture_headers) do
    if type(value) == "table" then
        capture_headers[key] = table.concat(value, ", ")
    end
end

local res = ngx.location.capture("@junction_upstream", {
    method = capture_method,
    args = ngx.req.get_uri_args(),
    body = ngx.req.get_body_data(),
    always_forward_body = true,
    copy_all_vars = true,
    headers = capture_headers,
})

if not res then
    return proxy_util.deny(ngx.HTTP_BAD_GATEWAY, "upstream capture failed")
end

if res.truncated then
    ngx.log(ngx.WARN, "junction capture truncated uri=", ngx.var.uri or "")
end

local body = res.body or ""
ngx.log(ngx.INFO, "junction capture uri=", ngx.var.uri or "",
    " status=", res.status, " upstream_bytes=", #body)

ngx.status = res.status

local skip_headers = {
    ["content-length"] = true,
    ["transfer-encoding"] = true,
    ["content-encoding"] = true,
    ["connection"] = true,
}

for key, value in pairs(res.header) do
    if not skip_headers[key:lower()] then
        ngx.header[key] = value
    end
end

local ctx = {
    session_id = ngx.ctx.session_id,
    junction_prefix = ngx.ctx.junction_prefix or device.junction_prefix,
    backend_base = ngx.ctx.backend_base,
}

local location = res.header["Location"]
if location and ctx.session_id and ctx.junction_prefix then
    local junction_base, junction_root = html_rewrite.junction_paths(
        ctx.junction_prefix,
        ctx.session_id
    )

    local rewritten = html_rewrite.rewrite_location(
        location,
        junction_base,
        junction_root,
        ctx.backend_base
    )

    if rewritten ~= location then
        ngx.header["Location"] = rewritten
    end
end

if device.on_response_headers then
    device.on_response_headers(ctx)
end

local content_type = res.header["Content-Type"]
local should_rewrite = html_rewrite.should_rewrite_response(content_type, ngx.var.uri)
if device.should_rewrite_body then
    should_rewrite = device.should_rewrite_body(content_type, ngx.var.uri)
end

if should_rewrite and #body > 0 then
    local before_len = #body
    local rewriter = device.rewrite_body or html_rewrite.rewrite
    body = rewriter(
        body,
        ctx.junction_prefix,
        ctx.session_id,
        ctx.backend_base
    )

    ngx.log(ngx.INFO, "junction rewrite applied uri=", ngx.var.uri or "",
        " bytes=", before_len, "->", #body)
elseif should_rewrite and #body == 0 then
    ngx.log(ngx.WARN, "junction rewrite skipped: empty upstream body uri=",
        ngx.var.uri or "", " status=", res.status,
        " content-type=", content_type or "(none)")
end

if body and #body > 0 then
    ngx.print(body)
end
