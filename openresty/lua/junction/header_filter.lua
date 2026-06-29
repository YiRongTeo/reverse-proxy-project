local cors = require "lib.cors"
local device_registry = require "lib.device_registry"
local html_rewrite = require "lib.html_rewrite"

local device_name = ngx.ctx.junction_device or ngx.var.junction_device
local device = device_registry.get(device_name)
if not device then
    return
end

local cors_opts = device.cors or {}

-- Remove upstream CORS headers that may conflict with junction-managed CORS.
ngx.header["Access-Control-Allow-Origin"] = nil
ngx.header["Access-Control-Allow-Credentials"] = nil
ngx.header["Access-Control-Allow-Headers"] = nil
ngx.header["Access-Control-Allow-Methods"] = nil
ngx.header["Access-Control-Expose-Headers"] = nil
ngx.header["Access-Control-Allow-Private-Network"] = nil

cors.apply_response_headers(cors_opts)

local ctx = {
    session_id = ngx.ctx.session_id,
    junction_prefix = ngx.ctx.junction_prefix or device.junction_prefix,
    backend_base = ngx.ctx.backend_base,
}

if device.on_response_headers then
    device.on_response_headers(ctx)
end

local content_type = ngx.header["Content-Type"]
local should_rewrite = html_rewrite.should_rewrite_response(content_type, ngx.var.uri)

if device.should_rewrite_body then
    should_rewrite = device.should_rewrite_body(content_type, ngx.var.uri)
end

local content_encoding = ngx.header["Content-Encoding"]
if content_encoding and content_encoding ~= "" and content_encoding ~= "identity" then
    if content_encoding ~= "gzip" then
        should_rewrite = false
        ngx.log(ngx.WARN, "junction rewrite skipped: unsupported Content-Encoding=",
            content_encoding, " uri=", ngx.var.uri)
    else
        -- Keep Content-Encoding: gzip so the gunzip filter can decompress before
        -- body_filter runs. Do not strip it here.
        ngx.log(ngx.INFO, "junction rewrite: upstream gzip body will be gunzipped (",
            ngx.var.uri, ")")
    end
end

if should_rewrite then
    ngx.ctx.rewrite_body = true
    ngx.var.rewrite_body = "1"
    ngx.header["Content-Length"] = nil
    ngx.header.content_length = nil
    ngx.log(ngx.INFO, "junction rewrite enabled for ", ngx.var.uri,
        " content-type=", content_type or "(none)")
else
    ngx.var.rewrite_body = "0"
    ngx.log(ngx.DEBUG, "junction rewrite disabled for ", ngx.var.uri,
        " content-type=", content_type or "(none)")
end

local location = ngx.header["Location"]
if location and ngx.ctx.session_id and ctx.junction_prefix then
    local junction_base, junction_root = html_rewrite.junction_paths(
        ctx.junction_prefix,
        ngx.ctx.session_id
    )

    local rewritten = html_rewrite.rewrite_location(
        location,
        junction_base,
        junction_root,
        ngx.ctx.backend_base
    )

    if rewritten ~= location then
        ngx.header["Location"] = rewritten
    end
end
