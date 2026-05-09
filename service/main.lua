local skynet_manager = require("skynet.manager")
local cluster = require("skynet.cluster")
local skynet = require("skynet")
local runconfig = require("runconfig")

skynet.start(function()
    --初始化
    local mynode = skynet.getenv("node")
    local nodecgf = runconfig[mynode]
    --开启节点管理服务
    local nodemgr = skynet.newservice("nodemgr", "nodemgr", 0)
    skynet.name("nodemgr", nodemgr)

    --集群配置
    cluster.reload(runconfig.cluster)
    cluster.open(mynode)
    --开启mysql代理服务
    if mynode == runconfig.mysqlproxy.node then
        local mysqlproxy = skynet.newservice("mysqlproxy", "mysqlproxy", 0)
        skynet.name("mysqlproxy", mysqlproxy)
    else
        local proxy = cluster.proxy(runconfig.mysqlproxy.node, "mysqlproxy")
        skynet.name("mysqlproxy", proxy)
    end
    --开启redis代理服务
    local redisproxy = skynet.newservice("redisproxy", "redisproxy", 0)
    skynet.name("redisproxy", redisproxy)
    --开启登录服务，网关服务
    for i, v in pairs(runconfig[mynode].gateway or {}) do --加上空表，防止配置表不存在时报错
        local srv = skynet.newservice("gateway", "gateway", i)
        skynet.name("gateway" .. i, srv)
    end
    for i, v in pairs(runconfig[mynode].login or {}) do
        local srv = skynet.newservice("login", "login", i)
        skynet.name("login" .. i, srv)
    end
    --开启战斗网关服务
    for i, v in pairs(runconfig[mynode].battle_gateway or {}) do
        local srv = skynet.newservice("battle_gateway", "battle_gateway", i)
        skynet.name("battle_gateway" .. i, srv)
    end
    --开启全局的agentmgr服务，并为其他节点设置代理
    if mynode == runconfig.agentmgr.node then
        local agentmgr = skynet.newservice("agentmgr", "agentmgr", 0)
        skynet.name("agentmgr", agentmgr)
    else
        local proxy = cluster.proxy(runconfig.agentmgr.node, "agentmgr")
        skynet.name("agentmgr", proxy)
    end

    --开启管理服务
    if mynode == runconfig.admin.node then
        local admin = skynet.newservice("admin", "admin", 0)
        skynet.name("admin", admin)
    end
    --开启定时服务
    if mynode == runconfig.cron.node then
        local cron = skynet.newservice("cron", "cron", 0)
        skynet.name("cron", cron)
    end
    --开启db同步服务
    if mynode == runconfig.dbsync.node then
        local dbsync = skynet.newservice("dbsync", "dbsync", 0)
        skynet.name("dbsync", dbsync)
    end
    --开启匹配服务
    if mynode == runconfig.match.node then
        local match = skynet.newservice("match", "match", 0)
        skynet.name("match", match)
    else
        local proxy = cluster.proxy(runconfig.match.node, "match")
        skynet.name("match", proxy)
    end
    --开启全局的roommgr服务
    if mynode == runconfig.roommgr.node then
        local roommgr = skynet.newservice("roommgr", "roommgr", 0)
        skynet.name("roommgr", roommgr)
    end
    --控制台服务
    local debug_console = skynet.newservice("debug_console", runconfig[mynode].debug_console.port)
    --热更新管理服务
    if mynode == runconfig.hotfixmgr.node then
        local hotfixmgr = skynet.newservice("hotfixmgr", "hotfixmgr", 0)
        skynet.name("hotfixmgr", hotfixmgr)
    end
    skynet.exit()
end)
