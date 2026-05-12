local skynet = require("skynet")
local s = require("service")
local mysql = require("skynet.db.mysql")
local redis = require("skynet.db.redis")
local pb = require("protobuf")
local cjson = require("cjson")
local db = nil
local rds = nil

local SYNC_INTERVAL = 300 --每5分钟落库

local function db_failed(res)
    return (not res) or res.badresult or res.errno
end

local function traceback(err)
    return debug.traceback(tostring(err))
end

----------------------------------指定同步-----------------------------------------------
--同步指定玩家的base_info
local function sync_player_base_info(playerid)
    local redis_key = "player:" .. tostring(playerid) .. ":base_info"
    local cached = rds:get(redis_key)
    if not cached then --缓存不存在
        skynet.error("[dbsync] Redis 无baseinfo数据，跳过playerid= " .. tostring(playerid))
        return false
    end
    local safe_playerid = db.quote_sql_str(playerid)
    local safe_data = db.quote_sql_str(cached)
    local sql =
        string.format("update role_message set data=%s where playerid=%s", safe_data, safe_playerid)
    local res = db:query(sql)
    if db_failed(res) then
        skynet.error("[dbsync]向mysql同步base_data失败: playerid=" .. tostring(playerid))
        return false
    end
    skynet.error("[dbsync]同步baseinfo成功：playerid=" .. tostring(playerid))
    return true
end

--同步指定玩家的achieves
local function sync_player_achieves(playerid)
    local redis_key = "player:" .. tostring(playerid) .. ":achieves"
    local cached = rds:hgetall(redis_key)
    if not cached or #cached == 0 then --缓存不存在
        skynet.error(
            "[dbsync] Redis 无achieves数据或为空，跳过playerid= " .. tostring(playerid)
        )
        return false
    end
    local achieves = {}
    for i = 1, #cached, 2 do
        local aid = cached[i]
        local ok, a = pcall(cjson.decode, cached[i + 1])
        if (not ok) or type(a) ~= "table" then
            skynet.error(
                "[dbsync] achieves解析失败: playerid="
                    .. tostring(playerid)
                    .. " aid="
                    .. tostring(cached[i])
            )
            return false
        end
        achieves[aid] = a
    end

    for aid, ach in pairs(achieves) do
        local safe_playerid = db.quote_sql_str(playerid)
        local safe_achieveid = db.quote_sql_str(aid)
        local safe_progress = db.quote_sql_str(ach.progress)
        local safe_isdone = db.quote_sql_str(ach.is_done)
        local safe_claim_time = ach.claim_time and db.quote_sql_str(ach.claim_time) or "NULL"
        local sql = string.format(
            "replace into achievement (playerid,achieve_id,progress,is_done,claim_time) value (%s,%s,%s,%s,%s)",
            safe_playerid,
            safe_achieveid,
            safe_progress,
            safe_isdone,
            safe_claim_time
        )
        local res = db:query(sql)
        if db_failed(res) then
            skynet.error(
                "[dbsync]向mysql同步成就数据失败: playerid="
                    .. tostring(playerid)
                    .. " aid="
                    .. tostring(aid)
            )
            return false
        end
    end
    skynet.error("[dbsync]向mysql同步成就数据成功: playerid=" .. tostring(playerid))
    return true
end
--同步指定玩家的bag
local function sync_player_bag(playerid)
    local redis_key = "player:" .. tostring(playerid) .. ":bag"
    local cached = rds:hgetall(redis_key)
    if not cached or #cached == 0 then --缓存不存在
        skynet.error(
            "[dbsync] Redis 无bag数据或为空，跳过playerid= " .. tostring(playerid)
        )
        return false
    end
    local items = {}
    for i = 1, #cached, 2 do
        local iid = cached[i]
        local ok, ite = pcall(cjson.decode, cached[i + 1])
        if (not ok) or type(ite) ~= "table" then
            skynet.error(
                "[dbsync] items解析失败: playerid="
                    .. tostring(playerid)
                    .. " iid="
                    .. tostring(cached[i])
            )
            return false
        end
        items[iid] = ite
    end

    for iid, ite in pairs(items) do
        local safe_playerid = db.quote_sql_str(playerid)
        local safe_item_id = db.quote_sql_str(iid)
        local safe_count = db.quote_sql_str(ite.count)
        local sql = string.format(
            "replace into bag (playerid,item_id,count) value (%s,%s,%s)",
            safe_playerid,
            safe_item_id,
            safe_count
        )
        local res = db:query(sql)
        if db_failed(res) then
            skynet.error(
                "[dbsync]向mysql同步背包数据失败: playerid="
                    .. tostring(s.id)
                    .. " item_id="
                    .. tostring(iid)
            )
            return false
        end
    end
    skynet.error("[dbsync]向mysql同步背包数据成功: playerid=" .. tostring(playerid))
    return true
end
-----------------------------------批量同步-----------------------------------------------

--批量同步base_info
local function sync_all_base_info()
    --检查是否有之前未处理的快照
    local has_syncing = rds:exists("dirty:base_info:syncing")
    if not has_syncing then --没有则创建新快照
        local ok, err = pcall(rds.rename, rds, "dirty:base_info", "dirty:base_info:syncing")
        if not ok then --没有脏玩家会rename失败
            return
        end
    end

    local dirty_ids = rds:smembers("dirty:base_info:syncing")
    if not dirty_ids then --如果读失败
        skynet.error("[dbsync] smembers failed,keep syncing snapshot for retry")

        return
    end
    if #dirty_ids == 0 then --脏玩家为空(之前某种原因没删这个空快照)
        rds:del("dirty:base_info:syncing")
        return
    end
    skynet.error("[dbsync]开启批量同步baseinfo,脏玩家数：" .. #dirty_ids)
    for _, pid in ipairs(dirty_ids) do
        local ok, synced = pcall(sync_player_base_info, pid)
        if not ok then
            skynet.error(
                "[dbsync] 同步base_info异常: playerid="
                    .. tostring(pid)
                    .. " err="
                    .. tostring(synced)
            )
        elseif synced then --同步成功,移除该玩家
            rds:srem("dirty:base_info:syncing", tostring(pid))
        end
    end

    --看看有没有剩下的玩家（即同步失败的）
    local remaining = rds:smembers("dirty:base_info:syncing")
    if remaining and #remaining > 0 then
        for _, pid in ipairs(remaining) do --有就写回脏集合
            rds:sadd("dirty:base_info", tostring(pid))
        end
    end
    rds:del("dirty:base_info:syncing")
end
--批量同步mail

--批量同步achieves
local function sync_all_achieves()
    --检查是否有之前未处理的快照
    local has_syncing = rds:exists("dirty:achieves:syncing")
    if not has_syncing then --没有则创建新快照
        local ok, err = pcall(rds.rename, rds, "dirty:achieves", "dirty:achieves:syncing")
        if not ok then --没有脏玩家会rename失败
            return
        end
    end
    local dirty_ids = rds:smembers("dirty:achieves:syncing")
    if not dirty_ids then --如果读失败
        skynet.error("[dbsync] smembers failed,keep syncing snapshot for retry")
        return
    end
    if #dirty_ids == 0 then --脏玩家为空
        rds:del("dirty:achieves:syncing")
        return
    end
    skynet.error("[dbsync]开启批量同步achieves,脏玩家数：" .. #dirty_ids)
    for _, pid in ipairs(dirty_ids) do
        local ok, synced = pcall(sync_player_achieves, pid) --pcall防止redis抛出lua错误
        if not ok then
            skynet.error(
                "[dbsync] 同步成就异常: playerid="
                    .. tostring(pid)
                    .. " err="
                    .. tostring(synced)
            )
        elseif synced then --同步成功,移除该玩家
            rds:srem("dirty:achieves:syncing", tostring(pid))
        end
    end

    --看看有没有剩下的玩家（即同步失败的）
    local remaining = rds:smembers("dirty:achieves:syncing")
    if remaining and #remaining > 0 then
        for _, pid in ipairs(remaining) do --有就写回脏集合
            rds:sadd("dirty:achieves", tostring(pid))
        end
    end
    rds:del("dirty:achieves:syncing")
end
--批量同步bag
local function sync_all_bag()
    --检查是否有之前未处理的快照
    local has_syncing = rds:exists("dirty:bag:syncing")
    if not has_syncing then --没有则创建新快照
        local ok, err = pcall(rds.rename, rds, "dirty:bag", "dirty:bag:syncing")
        if not ok then --没有脏玩家会rename失败
            return
        end
    end
    local dirty_ids = rds:smembers("dirty:bag:syncing")
    if not dirty_ids then --如果读失败
        skynet.error("[dbsync] smembers failed,keep syncing snapshot for retry")
        return
    end
    if #dirty_ids == 0 then --脏玩家为空
        rds:del("dirty:bag:syncing")
        return
    end
    skynet.error("[dbsync]开启批量同步bag,脏玩家数：" .. #dirty_ids)
    for _, pid in ipairs(dirty_ids) do
        local ok, synced = pcall(sync_player_bag, pid) --pcall防止redis抛出lua错误
        if not ok then
            skynet.error(
                "[dbsync] 同步背包异常: playerid="
                    .. tostring(pid)
                    .. " err="
                    .. tostring(synced)
            )
        elseif synced then --同步成功,移除该玩家
            rds:srem("dirty:bag:syncing", tostring(pid))
        end
    end

    --看看有没有剩下的玩家（即同步失败的）
    local remaining = rds:smembers("dirty:bag:syncing")
    if remaining and #remaining > 0 then
        for _, pid in ipairs(remaining) do --有就写回脏集合
            rds:sadd("dirty:bag", tostring(pid))
        end
    end
    rds:del("dirty:bag:syncing")
end

-------------------------------------------------------------------------------------------
--定时器用，批量扫描脏集合并且同步
local function sync_all_dirty()
    sync_all_base_info()
    sync_all_achieves()
    sync_all_bag()
end

--接受agent的请求：立即同步指定玩家的所有脏数据
function s.resp.sync_player(sourse, playerid)
    local err = ""
    --同步基础数据
    local ok = sync_player_base_info(playerid)
    if not ok then
        err = err .. "同步基础数据失败"
    end
    --同步成就
    ok = sync_player_achieves(playerid)
    if not ok then
        err = err .. "同步成就数据失败"
    end
    ok = sync_player_bag(playerid)
    if not ok then
        err = err .. "同步bag数据失败"
    end
    if err ~= "" then
        skynet.error("playerid: " .. playerid .. "请求立即同步数据出错：" .. err)
        return false
    end
    return true
end

function s.init()
    db = mysql.connect({
        host = "127.0.0.1",
        port = 3306,
        database = "player_message",
        user = "root",
        password = "123456",
        max_packet_size = 1024 * 1024, --最大接收包大小（1MB
        on_connect = nil, --连接建立时的回调函数
    })
    rds = redis.connect({
        host = "192.168.164.129",
        port = 6379,
        auth = "123456",
    })
    pb.register_file("./storage/GameData.pb")
    skynet.fork(function()
        while true do
            skynet.sleep(SYNC_INTERVAL * 100)
            local ok, err = xpcall(sync_all_dirty, traceback) --xpcall防止lua错误终止这个协程
            if not ok then
                skynet.error("[dbsync]定时同步异常：" .. tostring(err))
            end
        end
    end)
    skynet.error("[dbsync]服务启动成功")
end

s.start(...)
