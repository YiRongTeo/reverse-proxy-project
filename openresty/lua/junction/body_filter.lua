local device_registry = require "lib.device_registry"
local html_rewrite = require "lib.html_rewrite"

if not ngx.ctx.rewrite_body then
    return
end

local device_name = ngx.ctx.junction_device or ngx.var.junction_device
local device = device_registry.get(device_name)
if not device then
    return
end

local chunk = ngx.arg[1]
local eof = ngx.arg[2]

if not ngx.ctx.body_buffer then
    ngx.ctx.body_buffer = {}
end

if chunk and #chunk > 0 then
    table.insert(ngx.ctx.body_buffer, chunk)
end

if not eof then
    ngx.arg[1] = nil
    return
end

local body = table.concat(ngx.ctx.body_buffer)
ngx.ctx.body_buffer = nil

local before_len = #body
local rewriter = device.rewrite_body or html_rewrite.rewrite
body = rewriter(
    body,
    ngx.ctx.junction_prefix or device.junction_prefix,
    ngx.ctx.session_id,
    ngx.ctx.backend_base
)

if before_len > 0 then
    ngx.log(ngx.INFO, "junction rewrite applied uri=", ngx.var.uri or "",
        " bytes=", before_len, "->", #body)
end

ngx.arg[1] = body
