local device_registry = require "lib.device_registry"
local html_rewrite = require "lib.html_rewrite"

local rewrite_enabled = ngx.var.rewrite_body == "1" or ngx.ctx.rewrite_body == true

if not ngx.ctx.body_filter_seen then
    ngx.ctx.body_filter_seen = true
    ngx.log(ngx.INFO, "junction body_filter entered uri=", ngx.var.uri or "",
        " rewrite_var=", ngx.var.rewrite_body or "",
        " rewrite_ctx=", tostring(ngx.ctx.rewrite_body),
        " chunk_len=", #(ngx.arg[1] or ""),
        " eof=", tostring(ngx.arg[2]))
end

if not rewrite_enabled then
    return
end

local device_name = ngx.ctx.junction_device or ngx.var.junction_device
local device = device_registry.get(device_name)
if not device then
    ngx.log(ngx.WARN, "junction body_filter: unknown device ", tostring(device_name),
        " uri=", ngx.var.uri or "")
    return
end

local chunk = ngx.arg[1] or ""
local eof = ngx.arg[2]

ngx.ctx.buffered = (ngx.ctx.buffered or "") .. chunk

if not eof then
    -- Hold back output until the full body is buffered (OpenResty canonical pattern).
    ngx.arg[1] = ""
    return
end

local body = ngx.ctx.buffered
ngx.ctx.buffered = nil

local before_len = #body
local rewriter = device.rewrite_body or html_rewrite.rewrite
body = rewriter(
    body,
    ngx.ctx.junction_prefix or device.junction_prefix,
    ngx.ctx.session_id,
    ngx.ctx.backend_base
)

ngx.log(ngx.INFO, "junction rewrite applied uri=", ngx.var.uri or "",
    " bytes=", before_len, "->", #body)

ngx.arg[1] = body
