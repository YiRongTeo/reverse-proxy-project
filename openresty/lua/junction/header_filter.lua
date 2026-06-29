local cors = require "lib.cors"
local device_registry = require "lib.device_registry"

local device_name = ngx.ctx.junction_device or ngx.var.junction_device
local device = device_registry.get(device_name)
if not device then
    return
end

local cors_opts = device.cors or {}

ngx.header["Access-Control-Allow-Origin"] = nil
ngx.header["Access-Control-Allow-Credentials"] = nil
ngx.header["Access-Control-Allow-Headers"] = nil
ngx.header["Access-Control-Allow-Methods"] = nil
ngx.header["Access-Control-Expose-Headers"] = nil
ngx.header["Access-Control-Allow-Private-Network"] = nil

cors.apply_response_headers(cors_opts)
