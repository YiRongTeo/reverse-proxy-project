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

local ctx = {
    session_id = ngx.ctx.session_id,
    junction_prefix = ngx.ctx.junction_prefix or device.junction_prefix,
    backend_base = ngx.ctx.backend_base,
    backend_host = ngx.ctx.backend_host,
}

local upstream_headers = ngx.req.get_headers()
if ngx.ctx.backend_host then
    upstream_headers["Host"] = ngx.ctx.backend_host
end
upstream_headers["Accept-Encoding"] = "identity"

if device.prepare_upstream_headers then
    device.prepare_upstream_headers(upstream_headers, ctx)
end

local follow_redirects = device.follow_redirects
if device.should_follow_redirects then
    follow_redirects = device.should_follow_redirects(ngx.var.uri, method, follow_redirects)
end

local res, fetch_err = upstream_fetch.fetch(target_url, {
    method = method,
    args = ngx.var.args,
    uri = ngx.var.uri,
    headers = upstream_headers,
    body = ngx.req.get_body_data(),
    follow_redirects = follow_redirects,
    max_redirects = device.max_redirects,
    redirect_origin = ngx.ctx.backend_base,
})

if not res then
    ngx.log(ngx.ERR, "junction upstream fetch failed uri=", ngx.var.uri or "",
        " target=", target_url, " err=", fetch_err)
    return proxy_util.deny(ngx.HTTP_BAD_GATEWAY, fetch_err)
end

local body = res.body or ""
ngx.log(ngx.INFO, "junction upstream fetch uri=", ngx.var.uri or "",
    " target=", target_url, " status=", res.status, " upstream_bytes=", #body)

local junction_base, junction_root = html_rewrite.junction_paths(
    ctx.junction_prefix,
    ctx.session_id
)

local location = res.headers["Location"] or res.headers["location"]
local rewritten_location

if location and ctx.session_id then
    if device.rewrite_location then
        rewritten_location = device.rewrite_location(location, ctx)
    else
        rewritten_location = html_rewrite.rewrite_location(
            location,
            junction_base,
            junction_root,
            ctx.backend_base,
            ctx.backend_host
        )
    end

    if rewritten_location ~= location then
        ngx.log(ngx.INFO, "junction location rewritten ", location, " -> ", rewritten_location)
    else
        ngx.log(ngx.WARN, "junction location not rewritten: ", location)
    end
end

ngx.status = res.status

local skip_headers = {
    ["content-length"] = true,
    ["transfer-encoding"] = true,
    ["content-encoding"] = true,
    ["connection"] = true,
    ["location"] = true,
}

for key, value in pairs(res.headers) do
    if not skip_headers[key:lower()] then
        ngx.header[key] = value
    end
end

if rewritten_location then
    ngx.header["Location"] = rewritten_location
elseif location then
    ngx.header["Location"] = location
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
        ctx.backend_base,
        ctx.backend_host,
        {
            content_type = content_type,
            uri = ngx.var.uri,
            aggressive_absolute_rewrite = device.aggressive_absolute_rewrite == true,
        }
    )

    ngx.log(ngx.INFO, "junction rewrite applied uri=", ngx.var.uri or "",
        " bytes=", before_len, "->", #body)
elseif should_rewrite and #body == 0 then
    ngx.log(ngx.WARN, "junction rewrite skipped: empty upstream body uri=",
        ngx.var.uri or "", " status=", res.status,
        " content-type=", content_type or "(none)")
end

if device.finalize_response_headers then
    device.finalize_response_headers(ctx, body, res)
end

if body and #body > 0 then
    if res.status == 304 or res.status == 204 then
        ngx.status = ngx.HTTP_OK
    end
    ngx.print(body)
end
