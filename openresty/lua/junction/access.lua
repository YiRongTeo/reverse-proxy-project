local cors = require "lib.cors"
local device_registry = require "lib.device_registry"
local html_rewrite = require "lib.html_rewrite"
local proxy_util = require "lib.proxy_util"

local session_lookup = package.loaded["lib.junction_session"]
if type(session_lookup) ~= "table" then
    session_lookup = require "lib.junction_session"
end

if type(session_lookup) ~= "table" or type(session_lookup.extract_from_uri) ~= "function" then
    ngx.log(ngx.ERR, "lib.junction_session unavailable, got ", type(session_lookup))
    return proxy_util.deny(ngx.HTTP_INTERNAL_SERVER_ERROR, "session module unavailable")
end

local device_name = ngx.var.junction_device
local junction_prefix = ngx.var.junction_prefix

local device, device_err = device_registry.get(device_name)
if not device then
    return proxy_util.deny(ngx.HTTP_NOT_FOUND, device_err)
end

local prefix_candidates = {}
if junction_prefix ~= nil and junction_prefix ~= "" then
    prefix_candidates[#prefix_candidates + 1] = junction_prefix
end

if type(device.junction_prefixes) == "table" then
    for _, candidate in ipairs(device.junction_prefixes) do
        prefix_candidates[#prefix_candidates + 1] = candidate
    end
elseif device.junction_prefix then
    prefix_candidates[#prefix_candidates + 1] = device.junction_prefix
end

local cors_opts = device.cors or {}
if cors.handle_preflight(cors_opts) then
    return
end

local session_id, subpath, parse_err, matched_prefix = session_lookup.extract_from_uri(prefix_candidates)
if matched_prefix and matched_prefix ~= "" then
    junction_prefix = matched_prefix
elseif junction_prefix == nil or junction_prefix == "" then
    junction_prefix = device.junction_prefix or ""
end

if not session_id then
    ngx.log(ngx.WARN, "junction invalid session path uri=", ngx.var.uri or "",
        " prefix=", junction_prefix or "", " err=", parse_err or "")
    return proxy_util.deny(ngx.HTTP_BAD_REQUEST, parse_err)
end

ngx.log(ngx.INFO, "junction session path ok session_id=", session_id,
    " subpath=", subpath or "/", " prefix=", junction_prefix or "")

local session_data, lookup_err = session_lookup.lookup(session_id)
if not session_data then
    ngx.log(ngx.WARN, "junction session lookup failed session_id=", session_id,
        " err=", lookup_err or "")
    return proxy_util.deny(ngx.HTTP_UNAUTHORIZED,
        (lookup_err or "invalid session") .. " for session_id=" .. session_id)
end

if device.validate_session and not device.validate_session(session_id, session_data) then
    return proxy_util.deny(ngx.HTTP_FORBIDDEN, "session not allowed for this junction")
end

local target_url, build_err
if device.resolve_upstream_url then
    target_url, build_err = device.resolve_upstream_url(session_data.url, subpath)
else
    target_url, build_err = session_lookup.build_upstream_url(session_data.url, subpath)
end
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
ngx.ctx.junction_prefix = junction_prefix
ngx.ctx.session_id = session_id
ngx.ctx.backend_base = html_rewrite.backend_origin(
    session_data.url:gsub("/+$", ""),
    session_data.host or html_rewrite.extract_host(session_data.url)
)
ngx.ctx.backend_host = session_data.host
    or html_rewrite.extract_host(session_data.url)
    or session_data.url:match("^https?://([^:/]+)")
ngx.var.session_id = session_id
