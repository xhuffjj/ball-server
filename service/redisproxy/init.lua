local skynet = require("skynet")
local redis = require("skynet.db.redis")
local s = require("service")
local runconfig = require("runconfig")

local rds
local redis_opts

local function build_redis_opts()
    local cfg = runconfig.redis or {}
    return {
        host = cfg.host or "127.0.0.1",
        port = cfg.port or 6379,
        auth = cfg.auth,
    }
end

local function reconnect()
    pcall(rds.disconnect, rds)
    rds = redis.connect(redis_opts)
end

local function call_redis(cmd, ...)
    local fn = rds[cmd]
    local ret = table.pack(pcall(fn, rds, ...))
    if ret[1] then
        return true, table.unpack(ret, 2, ret.n)
    end

    skynet.error(
        string.format("[redisproxy] cmd error cmd=%s err=%s", tostring(cmd), tostring(ret[2]))
    )
    pcall(reconnect)
    return false, ret[2]
end

function s.resp.cmd(source, cmd, ...)
    return call_redis(cmd, ...)
end

--查看redis连接状态
function s.resp.state()
    return {
        connected = rds ~= nil,
    }
end

function s.init()
    redis_opts = build_redis_opts()
    rds = redis.connect(redis_opts)
    skynet.error("[redisproxy] started")
end

s.start(...)
