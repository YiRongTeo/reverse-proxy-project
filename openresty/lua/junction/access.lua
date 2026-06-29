local cors = require "lib.cors"
local device_registry = require "lib.device_registry"
local proxy_util = require "lib.proxy_util"
local session = require "lib.session"

local device_name = ngx.var.junction_device
local junction_prefix = ngx.var.junction_prefix

local device, device_err = device_registry.get(device_name)
if not device then
    return proxy_util.deny(ngx.HTTP_NOT_FOUND, device_err)
end

local cors_opts = device.cors or {}
if cors.handle_preflight(cors_opts) then
    return
end

local session_id, subpath, parse_err = session.extract_from_uri(junction_prefix)
if not session_id then
    return proxy_util.deny(ngx.HTTP_BAD_REQUEST, parse_err)
end

local session_data, lookup_err = session.lookup(session_id)
if not session_data then
    return proxy_util.deny(ngx.HTTP_UNAUTHORIZED, lookup_err or "invalid session")
end

if device.validate_session and not device.validate_session(session_id, session_data) then
    return proxy_util.deny(ngx.HTTP_FORBIDDEN, "session not allowed for this junction")
end

local target_url, build_err = session.build_upstream_url(session_data.url, subpath)
if not target_url then
    return proxy_util.deny(ngx.HTTP_BAD_GATEWAY, build_err)
end

if device.before_proxy then
    local ok, before_err = device.before_proxy({
        session_id = session_id,
        subpath = subpath,
        session = session_data,
        target_url = target_url,
    })

    if ok == false then
        return proxy_util.deny(ngx.HTTP_BAD_GATEWAY, before_err or "device pre-proxy hook failed")
    end
end

local upstream_ok, upstream_err = proxy_util.set_upstream(target_url)
if not upstream_ok then
    return proxy_util.deny(ngx.HTTP_BAD_GATEWAY, upstream_err)
end

proxy_util.preserve_client_ip()

if device.configure_request_headers then
    device.configure_request_headers({
        session_id = session_id,
        subpath = subpath,
        session = session_data,
        target_url = target_url,
    })
end

ngx.ctx.junction_device = device_name
ngx.ctx.session_id = session_id
ngx.var.session_id = session_id
