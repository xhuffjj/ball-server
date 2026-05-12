local skynet = require("skynet")
local s = require("service")
local cjson = require("cjson")
local REDIS_TTL = 1 * 1 * 3600
--成就配置
local ACHIEVE_CONFIG = require("achieve_config")

local function db_failed(res)
    return (not res) or res.badresult or res.errno
end

--[event]->用于初始化新增成就的成就记录，查对应事件当前进度的函数
local event_progress_handlers = {}

--成就记录类
local function achieve(achieve_id)
    local m = {
        achieve_id = achieve_id,
        progress = 0,
        is_done = 0,
        claim_time = nil,
    }
    return m
end

--成就记录表[achieve_id]=achieve
s.data.achieves = s.data.achieves or {}
--成就记录加载到内存
function s.achieve_init()
    local redis_key = "player:" .. tostring(s.id) .. ":achieves"
    local cached = s.rds:hgetall(redis_key)
    --命中
    if cached and #cached > 0 then
        for i = 1, #cached, 2 do
            local aid = tonumber(cached[i])
            local a = cjson.decode(cached[i + 1])
            s.data.achieves[aid] = a
        end
    else --未命中,未命中返回的是空表
        local safe_playerid = s.db.quote_sql_str(s.id)
        local sql = string.format(
            "select achieve_id,progress,is_done,claim_time from achievement where playerid=%s",
            safe_playerid
        )
        local res = s.db:query(sql)
        if db_failed(res) then
            error("加载玩家成就数据失败: playerid=" .. tostring(s.id))
        end
        for _, row in ipairs(res) do
            local a = achieve()
            a.achieve_id = row.achieve_id
            a.progress = row.progress
            a.is_done = row.is_done
            a.claim_time = row.claim_time
            s.data.achieves[row.achieve_id] = a
        end
        --回填redis
        for aid, a in pairs(s.data.achieves) do
            local value = cjson.encode(a)
            s.rds:hset(redis_key, tostring(aid), value)
        end
    end
    --设置redis过期时间
    if next(s.data.achieves) then
        s.rds:expire(redis_key, REDIS_TTL)
    end

    --把新增成就加进内存来
    local has_new_achieve = false
    for aid, cfg in pairs(ACHIEVE_CONFIG.achieve_list) do
        if s.data.achieves[aid] == nil then
            if event_progress_handlers[cfg.event] then
                local delta = event_progress_handlers[cfg.event]()
                s.achieve_progress(aid, delta)
                has_new_achieve = true
            end
        end
    end
    --新增成就会修改内存，需要落盘
    if has_new_achieve then
        s.dirty.achieves = true
    end
end

--客户端请求成就记录列表
function s.client.achieve_list(msg)
    local list = {}
    for aid, cfg in pairs(ACHIEVE_CONFIG.achieve_list) do
        local data = s.data.achieves[aid] or achieve(aid)
        table.insert(list, data)
    end
    return { "achieve_list", achieves = list }
end

--客户端请求领取成就奖励
function s.client.achieve_claim(msg)
    local aid = msg.achieve_id
    local cfg = ACHIEVE_CONFIG.achieve_list[aid]
    if not cfg then
        return { "achieve_claim", code = 1, msg = "成就不存在" }
    end
    local a = s.data.achieves[aid]
    if not a or a.is_done == 0 then
        return { "achieve_claim", code = 1, msg = "成就未完成" }
    end
    if a.claim_time then
        return { "achieve_claim", code = 1, msg = "已经领取过" }
    end

    --发放奖励
    s.data.base_info.coin = s.data.base_info.coin + cfg.reward_coin
    a.claim_time = os.date("%Y-%m-%d %H:%M:%S")

    --标脏
    s.dirty.achieves = true

    --同时触发金币类成就
    s.achieve_trigger("earn_coin", cfg.reward_coin)
    s.dirty.base_info = true
    return { "achieve_claim", code = 0, msg = "领取成功" }
end

--推进成就
function s.achieve_progress(achieve_id, delta)
    local cfg = ACHIEVE_CONFIG.achieve_list[achieve_id]
    if not cfg then
        return false
    end
    local a = s.data.achieves[achieve_id]
    if not a then
        a = achieve(achieve_id)
        s.data.achieves[achieve_id] = a
    end

    a.progress = a.progress + delta

    if a.progress >= cfg.target and a.is_done == 0 then --首次完成
        a.is_done = 1
        local msg = {
            "achieve_notify",
            achieveinfo = {
                achieve_id = achieve_id,
                progress = a.progress,
                is_done = a.is_done,
                claim_time = a.claim_time,
            },
        }
        --新增成就会在玩家登录时推进，此时agent服务还在初始化
        --然而s.gate是在agent服务启动后的第一条消息初始化的，
        --所以s.gate是有可能为空的
        if s.gate then
            skynet.send(s.gate, "lua", "send", s.id, msg)
        end
    end
end

--推进所有事件相关的成就
function s.achieve_trigger(event, delta)
    local achieve_ids = ACHIEVE_CONFIG.event_list[event]
    if not achieve_ids then
        return false
    end
    s.dirty.achieves = true
    for _, aid in ipairs(achieve_ids) do
        s.achieve_progress(aid, delta)
    end
    return true
end

--下线保存数据
function s.save_achieve()
    local redis_key = "player:" .. tostring(s.id) .. ":achieves"
    local fv = {}
    for aid, ach in pairs(s.data.achieves) do
        fv[#fv + 1] = tostring(aid)
        fv[#fv + 1] = cjson.encode(ach)
    end
    if #fv == 0 then --空成就，无需保存
        return true
    end
    local ok, err = pcall(s.rds.hmset, s.rds, redis_key, table.unpack(fv))
    if not ok then
        skynet.error("向redis写achieves失败：playerid=" .. tostring(s.id) .. ",error= " .. err)
        --应该把这个不完整的从redis删了
        s.rds:del(redis_key)

        --mysql兜底
        for aid, ach in pairs(s.data.achieves) do
            local safe_playerid = s.db.quote_sql_str(s.id)
            local safe_achieveid = s.db.quote_sql_str(aid)
            local safe_progress = s.db.quote_sql_str(ach.progress)
            local safe_isdone = s.db.quote_sql_str(ach.is_done)
            local safe_claim_time = ach.claim_time and s.db.quote_sql_str(ach.claim_time) or "NULL"
            local sql = string.format(
                "replace into achievement (playerid,achieve_id,progress,is_done,claim_time) value (%s,%s,%s,%s,%s)",
                safe_playerid,
                safe_achieveid,
                safe_progress,
                safe_isdone,
                safe_claim_time
            )
            local res = s.db:query(sql)
            if db_failed(res) then
                skynet.error(
                    "保存成就数据失败: playerid="
                        .. tostring(s.id)
                        .. " aid="
                        .. tostring(aid)
                )
                return false
            end
        end

        return true
    end
    s.rds:expire(redis_key, REDIS_TTL)
    s.rds:sadd("dirty:achieves", s.id)
    return true
end

function event_progress_handlers.earn_coin()
    return s.data.base_info.coin
end
