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
local should_rewrite = false

if device.should_rewrite_body then
    should_rewrite = device.should_rewrite_body(content_type)
elseif html_rewrite.should_rewrite_content_type(content_type) then
    should_rewrite = true
end

if ngx.header["Content-Encoding"] and ngx.header["Content-Encoding"] ~= "identity" then
    should_rewrite = false
    ngx.log(ngx.WARN, "skipping body rewrite for encoded response: ", ngx.header["Content-Encoding"])
end

if should_rewrite then
    ngx.ctx.rewrite_body = true
    ngx.header["Content-Length"] = nil
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
