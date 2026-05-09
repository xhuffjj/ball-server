local skynet = require("skynet")
local s = require("service")
local mysql = require("skynet.db.mysql")

STATUS = {
    LOGIN = 2,
    GAME = 3,
    LOGOUT = 4,
}

local player_versions = {}

local function next_login_version(playerid)
    local v = (player_versions[playerid] or 0) + 1
    player_versions[playerid] = v
    return v
end
local db = nil
local players = {}
local function db_failed(res)
    return (not res) or res.badresult or res.errno
end
local function db_failed_err(res)
    return string.format(
        "insert mails failed | errno=%s | badresult=%s | err=%s",
        tostring(res and res.errno),
        tostring(res and res.badresult),
        tostring(res and res.err)
    )
end

local function mgrplayer()
    local m = {
        playerid = nil,
        node = nil,
        gate = nil,
        agent = nil,
        status = nil,
        login_version = nil,
    }
    return m
end

function s.resp.reqlogin(source, playerid, node, gate)
    local mplayer = players[playerid]
    if mplayer and mplayer.status == STATUS.LOGIN then
        skynet.error("reqlogin failed ,at status LOGIN" .. playerid)
        return false
    end
    if mplayer and mplayer.status == STATUS.LOGOUT then
        skynet.error("reqlogin failed ,at status LOGOUT" .. playerid)
        return false
    end
    local new_version = next_login_version(playerid)
    if mplayer then --在线
        --把玩家踢下线
        local pnode = mplayer.node
        local pgate = mplayer.gate
        local pagent = mplayer.agent
        mplayer.status = STATUS.LOGOUT
        --如果pnode挂了，或者pagent某种原因不存在了，那么s.call会报错，可以用pcall调用s.call防止服务器因为某一节点或者玩家整个崩溃
        pcall(s.call, pnode, pagent, "kick")
        s.send(pnode, pagent, "exit")
        s.send(pnode, pgate, "send", playerid, { "kick", msg = "顶替下线" })
        pcall(s.call, pnode, pgate, "kick", playerid)
    end

    local player = mgrplayer()
    player.playerid = playerid
    player.node = node
    player.gate = gate
    player.status = STATUS.LOGIN
    player.agent = nil
    player.login_version = new_version
    players[playerid] = player

    local ok, agent =
        pcall(s.call, node, "nodemgr", "newservice", "agent", "agent", playerid, new_version)
    if not ok or not agent then
        skynet.error("reqlogin create agent failed for " .. playerid)
        players[playerid] = nil --失败必须清理数据，否则玩家卡死在 LOGIN 状态
        return false
    end
    player.agent = agent
    --player.status = STATUS.GAME
    return true, agent, new_version
end

function s.resp.confirm_login(source, playerid, is_succ)
    local mplayer = players[playerid]
    if not mplayer then
        return false
    end
    if mplayer.status ~= STATUS.LOGIN or not is_succ then
        players[playerid] = nil
        pcall(s.call, mplayer.node, mplayer.agent, "kick")
        s.send(mplayer.node, mplayer.agent, "exit")
        return false
    end
    mplayer.status = STATUS.GAME
    return true
end

function s.resp.reqkick(source, playerid, reason, login_version)
    skynet.error("[agentmgr] 收到" .. playerid .. "下线请求，原因：" .. reason)
    local mplayer = players[playerid]
    if not mplayer then
        return false
    end
    if mplayer.login_version ~= login_version then
        return false
    end
    if mplayer and mplayer.status ~= STATUS.GAME then
        return false
    end

    local pnode = mplayer.node
    local pagent = mplayer.agent
    local pgate = mplayer.gate
    mplayer.status = STATUS.LOGOUT
    pcall(s.call, pnode, pagent, "kick")
    s.send(pnode, pagent, "exit")
    s.send(pnode, pgate, "kick", playerid)
    players[playerid] = nil
    return true
end

--供其他服务查询玩家是否在线
function s.resp.get_player(sourse, playerid)
    if players[playerid] and players[playerid].status == STATUS.GAME then
        return players[playerid]
    end
end

--供其他服务批量查询玩家是否在线
function s.resp.get_players(sourse, playerid_list)
    local result = {}
    for _, playerid in ipairs(playerid_list) do
        if players[playerid] and players[playerid].status == STATUS.GAME then
            result[playerid] = players[playerid]
        end
    end
    return result
end

local function get_online_count()
    local count = 0
    for playerid, player in pairs(players) do
        count = count + 1
    end
    return count
end

--把玩家尽量踢掉num个，但实际只会踢能踢掉的玩家
function s.resp.shutdown(sourse, num)
    --踢下线
    local n = 0
    for playerid, player in pairs(players) do
        if player.status == STATUS.GAME then
            local ok, can_kick = pcall(s.call, player.node, player.agent, "can_shutdown_kick")
            if ok and can_kick then
                skynet.fork(s.resp.reqkick, nil, playerid, "close server", player.login_version)
                n = n + 1
                if n >= num then
                    break
                end
            end
        end
    end
    skynet.sleep(200)
    local new_count = get_online_count()
    skynet.error("shutdown online : " .. new_count)

    return new_count
end

--通知在线玩家新邮件
function s.resp.notify_new_mails(source, batch_id)
    local targets = {} --快照，因为在pairs遍历过程中，如果这个表注入了全新的key，那么next函数的行为是未定义的
    for playerid, player in pairs(players) do
        if player.status == STATUS.GAME then
            table.insert(targets, playerid)
        end
    end

    --发100个玩家就睡眠10ms，给其他任务留执行机会
    for i, playerid in ipairs(targets) do
        --这里player有可能下线，我们还需判断
        local player = players[playerid]
        if player and player.status == STATUS.GAME then
            s.send(player.node, player.agent, "new_mail", nil, batch_id)
            if i % 100 == 0 then
                skynet.sleep(1)
            end
        end
    end
end

--通知在线玩家更新每日任务
function s.resp.daily_reset(sourse)
    local targets = {} --快照，因为在pairs遍历过程中，如果这个表注入了全新的key，那么next函数的行为是未定义的
    for playerid, player in pairs(players) do
        if player.status == STATUS.GAME then
            table.insert(targets, playerid)
        end
    end
    skynet.error("[agentmgr] 广播daily_reset给" .. #targets .. "个在线玩家")
    --发100个玩家就睡眠10ms，给其他任务留执行机会
    for i, playerid in ipairs(targets) do
        --这里player有可能下线，我们还需判断
        local player = players[playerid]
        if player and player.status == STATUS.GAME then
            s.send(player.node, player.agent, "first_login_day")
            if i % 100 == 0 then
                skynet.sleep(1)
            end
        end
    end
    return true
end

local function hotfix_online_agents(cmd, ...)
    local targets = {}
    for playerid, player in pairs(players) do
        if player.status == STATUS.GAME then
            table.insert(targets, playerid)
        end
    end
    local result = {
        total = #targets,
        ok = 0,
        failed = {},
    }
    for i, playerid in ipairs(targets) do
        local player = players[playerid]
        if player and player.status == STATUS.GAME then
            local ok, ret, err = pcall(s.call, player.node, player.agent, cmd, ...)
            if not ok or not ret then
                table.insert(result.failed, {
                    playerid = playerid,
                    err = tostring(err or ret),
                })
            else
                result.ok = result.ok + 1
            end
            if i % 100 == 0 then
                skynet.sleep(1)
            end
        else
            table.insert(result.failed, {
                playerid = playerid,
                err = "agent非GAME状态",
            })
        end
    end
    skynet.error({
        string.format(
            "[agentmgr] hotfix_online_agents %s total=%d ok=%d failed=%d",
            cmd,
            result.total,
            result.ok,
            #result.failed
        ),
    })
    return true, result
end

function s.resp.hotfix_agents_module(source, modname, reload_config)
    return hotfix_online_agents("hotfix_module", modname, reload_config)
end

function s.resp.hotfix_agents_config(source, config_name)
    return hotfix_online_agents("hotfix_config", config_name)
end
s.start(...)
