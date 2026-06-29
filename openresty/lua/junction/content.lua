local device_registry = require "lib.device_registry"
local html_rewrite = require "lib.html_rewrite"
local proxy_util = require "lib.proxy_util"
local upstream_fetch = require "lib.upstream_fetch"

local device_name = ngx.ctx.junction_device or ngx.var.junction_device
local device = device_registry.get(device_name)
if not device then
    return proxy_util.deny(ngx.HTTP_NOT_FOUND, "unknown device junction")
end

local target_url = ngx.var.device_upstream
if not target_url or target_url == "" then
    return proxy_util.deny(ngx.HTTP_BAD_GATEWAY, "missing upstream url")
end

local method = ngx.req.get_method()
if method == "POST" or method == "PUT" or method == "PATCH" or method == "DELETE" then
    ngx.req.read_body()
end

local res, fetch_err = upstream_fetch.fetch(target_url, {
    method = method,
    args = ngx.var.args,
    headers = ngx.req.get_headers(),
    body = ngx.req.get_body_data(),
})

if not res then
    ngx.log(ngx.ERR, "junction upstream fetch failed uri=", ngx.var.uri or "",
        " target=", target_url, " err=", fetch_err)
    return proxy_util.deny(ngx.HTTP_BAD_GATEWAY, fetch_err)
end

local body = res.body or ""
ngx.log(ngx.INFO, "junction upstream fetch uri=", ngx.var.uri or "",
    " target=", target_url, " status=", res.status, " upstream_bytes=", #body)

ngx.status = res.status

local skip_headers = {
    ["content-length"] = true,
    ["transfer-encoding"] = true,
    ["content-encoding"] = true,
    ["connection"] = true,
    ["etag"] = true,
    ["last-modified"] = true,
}

for key, value in pairs(res.headers) do
    if not skip_headers[key:lower()] then
        ngx.header[key] = value
    end
end

local ctx = {
    session_id = ngx.ctx.session_id,
    junction_prefix = ngx.ctx.junction_prefix or device.junction_prefix,
    backend_base = ngx.ctx.backend_base,
}

local location = res.headers["Location"] or res.headers["location"]
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

local content_type = res.headers["Content-Type"] or res.headers["content-type"]
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
    if res.status == 304 then
        return proxy_util.deny(ngx.HTTP_BAD_GATEWAY,
            "upstream returned 304 Not Modified with no body")
    end
end

if should_rewrite and #body > 0 then
    ngx.header["Cache-Control"] = "no-store, no-cache, must-revalidate, private"
    ngx.header["Pragma"] = "no-cache"
end

if body and #body > 0 then
    if res.status == 304 or res.status == 204 then
        ngx.status = ngx.HTTP_OK
    end
    ngx.print(body)
end
