local skynet = require("skynet")
local s = require("service")
local redis = require("skynet.db.redis")
local runconfig = require("runconfig")
local cjson = require("cjson")
local queue = require("skynet.queue")

local state_lock = queue()
local shutting_down = false

local STATE = {
    IDLE = 0,
    MATCHING = 1,
    ROOM_ALLOCATING = 2,
    ROOM_PREPARING = 3,
    RUNNING = 4,
}
--新建玩家匹配状态及相关数据
local function empty_player_state(playerid)
    return {
        playerid = playerid,
        state = STATE.IDLE,
        mode_id = nil,
        room_node = nil,
        room_id = nil,
        room = nil, --skynet服务句柄
        scene_addr = nil,
        alloc_version = nil, --分配房间的版本号，区别每次成功匹配的分配房间申请
        agent_node = nil,
        agent = nil,
        rank_score = nil, --段位分
        segment_id = nil, --玩家段位位于的桶号
        queue_enter_ms = nil, --玩家匹配了多久
    }
end
--玩家状态的redis key
local function player_key(playerid)
    return "match:player:" .. tostring(playerid)
end
--匹配队列的redis键，指明模式号和段位桶号
local function queue_key(mode_id, segment_id)
    return "match:queue:" .. tostring(mode_id) .. ":" .. tostring(segment_id)
end
--活跃段位桶号集合的redis key，指明模式号
local function active_segments_key(mode_id)
    return "match:active_segment:" .. tostring(mode_id)
end

--将redis的json玩家状态解码到内存
local function decode_player_state(raw, playerid)
    local ret = empty_player_state(playerid)
    local data = cjson.decode(raw)

    ret.state = tonumber(data.state)
    ret.mode_id = tonumber(data.mode_id)
    ret.room_node = data.room_node
    ret.room_id = tonumber(data.room_id)
    ret.room = tonumber(data.room)
    ret.scene_addr = tonumber(data.scene_addr)
    ret.alloc_version = tonumber(data.alloc_version)
    ret.agent_node = data.agent_node
    ret.agent = tonumber(data.agent)
    ret.rank_score = tonumber(data.rank_score)
    ret.segment_id = tonumber(data.segment_id)
    ret.queue_enter_ms = tonumber(data.queue_enter_ms)
    return ret
end

local rds
local alloc_version
--[alloc_version]->{canceled = false,playerids = {...} }
local alloc_records = {}

--匹配配置，每个模式的匹配配置
local MATCH_CONFIG = {
    [1] = {
        player_num = 2,
        segment_span = 100, --分段跨度，100分为1个分段
        expand_interval_ms = 5000, --扩圈间隔，每5s扩大段位搜索范围
        max_expand_segment = 1, --最大前后各扩1个分段
    },
    [2] = {
        player_num = 4,
        segment_span = 100, --分段跨度，100分为1个分段
        expand_interval_ms = 5000, --扩圈间隔，每5s扩大段位搜索范围
        max_expand_segment = 3, --最大前后各扩3个分段
    },
}

local SCAN_INTERVAL = 50 --每0.5s扫描一次redis的所有匹配队列

--当前毫秒数,给匹配等待时长计算用
local function now_ms()
    return skynet.now() * 10
end
--计算玩家的段位桶号
local function cal_segment(rank_score, segment_span)
    return math.floor(rank_score / segment_span)
end
--根据玩家的等待时间计算左右跨几个桶搜索
local function cal_expand_segment(info, cfg)
    local step = math.floor((now_ms() - info.queue_enter_ms) / cfg.expand_interval_ms)
    local span = math.min(cfg.max_expand_segment, step)
    if span < 0 then
        span = 0
    end
    return span
end

--从redis读取玩家状态
local function load_player_state(playerid)
    playerid = tonumber(playerid)
    local raw = rds:get(player_key(playerid))
    if not raw then
        return empty_player_state(playerid)
    end
    return decode_player_state(raw, playerid)
end

--玩家匹配状态保存到redis
local function save_player_state(data)
    rds:set(player_key(data.playerid), cjson.encode(data))
end

--清理玩家在redis的匹配状态
local function clear_player_state(playerid)
    rds:del(player_key(playerid))
end

local function next_alloc_version()
    alloc_version = (alloc_version or 0) + 1
    return alloc_version
end

--记录这次参与申请建房的玩家，用于后续建房完成返回后判断这次分配是否被取消
local function record_alloc(batch, alloc_version)
    local record = {
        canceled = false,
        playerids = {},
    }
    for _, info in ipairs(batch) do
        table.insert(record.playerids, info.playerid)
    end
    alloc_records[alloc_version] = record
end

--将alloc_records的某次分配标记为取消
local function cancel_alloc(alloc_version)
    local record = alloc_records[alloc_version]
    if record then
        record.canceled = true
    end
end
--从指定桶中取出有效的玩家,取limit个
local function fetch_vaild_from_segment(mode_id, segment_id, limit)
    local key = queue_key(mode_id, segment_id)
    local raw_list = rds:zrange(key, 0, limit - 1) or {}
    local ret = {}
    for _, playerid_str in ipairs(raw_list) do
        local playerid = tonumber(playerid_str)
        local info = load_player_state(playerid)
        if
            info.state ~= STATE.MATCHING
            or info.mode_id ~= mode_id
            or info.segment_id ~= segment_id
        then
            --说明这是条旧记录，并且此时不应该存在于这个桶，应该删了
            rds:zrem(key, tostring(playerid))
        else
            table.insert(ret, info)
        end
    end
    --桶空了，就从桶活跃集合里面把桶号删了
    if #raw_list == 0 then
        rds:srem(active_segments_key(mode_id), tostring(segment_id))
    end
    return ret
end

--从中心段位桶取出一批玩家
local function collect_batch(mode_id, center_segment, cfg)
    local need_num = cfg.player_num
    --先从中心桶取入桶最早的玩家作为判断应该跨几个桶凑玩家的依据
    local center_first_player_list = fetch_vaild_from_segment(mode_id, center_segment, 1)
    local center_first_player = center_first_player_list[1]
    --如果中心桶没有玩家了，返回空表
    if not center_first_player then
        return {}
    end
    --计算要跨几个段
    local expand = cal_expand_segment(center_first_player, cfg)
    local batch = { center_first_player }
    --防止重复
    local used = { [center_first_player.playerid] = true }
    --从本桶开始，逐渐扩大搜索范围到expand
    for diff = 0, expand do
        local segment_ids = {}
        if diff == 0 then
            segment_ids = { center_segment }
        else
            segment_ids = { math.max(center_segment - diff, 0), center_segment + diff }
        end

        for _, segment_id in ipairs(segment_ids) do
            --从segment_id段取多点，need_num*2，防止fetch_vaild_from_segment从桶取回玩家的不一定都有效导致数量不够
            local list = fetch_vaild_from_segment(mode_id, segment_id, need_num * 2)
            for _, info in ipairs(list) do
                if not used[info.playerid] then
                    used[info.playerid] = true

                    table.insert(batch, info)
                    if #batch >= need_num then
                        return batch
                    end
                end
            end
        end
    end
    --如果搜索到expand没凑够，返回空表
    return {}
end

--把本批玩家状态改为room_allocating,同时记录请求分配记录,把玩家从匹配桶移除
local function mark_batch_allocating(batch, mode_id, alloc_version)
    record_alloc(batch, alloc_version)
    for _, info in ipairs(batch) do
        local key = queue_key(mode_id, info.segment_id)
        rds:zrem(key, tostring(info.playerid))
        info.state = STATE.ROOM_ALLOCATING
        info.alloc_version = alloc_version
        --状态写回redis
        save_player_state(info)
    end
end

--开房间失败时，将状态未改变的玩家加回匹配队列,同时回退这些玩家的状态,清理分配记录
local function requeue_batch(batch, mode_id, alloc_version)
    for _, old in ipairs(batch) do
        --加载玩家最新状态
        local info = load_player_state(old.playerid)
        --如果玩家状态改变或者有了新的房间分配号
        if info.state ~= STATE.ROOM_ALLOCATING or info.alloc_version ~= alloc_version then
            goto continue
        end
        --否则我们把玩家放回匹配队列,并且回退状态
        info.state = STATE.MATCHING
        info.alloc_version = nil
        save_player_state(info)

        --放回匹配队列
        local key = queue_key(mode_id, info.segment_id)
        rds:zadd(key, tostring(info.queue_enter_ms), tostring(info.playerid))
        key = active_segments_key(mode_id)
        rds:sadd(key, tostring(info.segment_id))
        ::continue::
    end

    alloc_records[alloc_version] = nil
end

--判断这批alloc是否被取消或者这批玩家的状态有改动
local function alloc_canceled(batch, alloc_version)
    local record = alloc_records[alloc_version]
    --alloc是否标记取消
    if not record or record.canceled == true then
        return true
    end
    --是否有玩家的状态改变
    for _, old in ipairs(batch) do
        local info = load_player_state(old.playerid)
        if info.state ~= STATE.ROOM_ALLOCATING or info.alloc_version ~= alloc_version then
            return true
        end
    end
    return false
end

--推动玩家状态到room_preparing状态
local function mark_batch_preparing(batch, room_info, alloc_version)
    for _, old in ipairs(batch) do
        local info = load_player_state(old.playerid)
        info.state = STATE.ROOM_PREPARING
        info.room_id = room_info.room_id
        info.room = room_info.room
        info.room_node = room_info.room_node
        info.scene_addr = room_info.scene_addr
        info.alloc_version = nil
        save_player_state(info)
    end

    alloc_records[alloc_version] = nil
end

--通知玩家匹配成功
local function notify_match_found(batch)
    local playerids = {}
    for _, member in ipairs(batch) do
        table.insert(playerids, member.playerid)
    end

    for _, info in ipairs(batch) do
        if info.agent and info.agent_node then
            s.send(info.agent_node, info.agent, "send", {
                "match_found",
                playerids = playerids,
            })
        end
    end
end

--扫描某个模式，尝试凑够玩家并且申请开房间
--返回true表示凑出了一个房间，返回false表示这个模式已经凑不出房间了
local function try_match(mode_id)
    local batch
    local alloc_version

    local cfg = MATCH_CONFIG[mode_id]
    if not cfg then
        return false
    end
    --加协程锁,扫描玩家以及状态转移期间不处理leave和cancle和join
    --从活跃桶集合读取活跃桶号
    local ok = state_lock(function()
        local raw_segments = rds:smembers(active_segments_key(mode_id)) or {}
        local segments = {}
        for _, segment_id in ipairs(raw_segments) do
            table.insert(segments, tonumber(segment_id))
        end
        table.sort(segments, function(a, b)
            return tonumber(a) < tonumber(b)
        end)
        batch = {}

        --从低段位到高段位扫描,扫描出第一批玩家就停止
        for _, segment_id in ipairs(segments) do
            batch = collect_batch(mode_id, segment_id, cfg)
            if #batch >= cfg.player_num then
                break
            end
        end
        --如果没有没扫到玩家，返回false
        if #batch < cfg.player_num then
            return false
        end

        alloc_version = next_alloc_version()
        --状态转移到room_allocating
        mark_batch_allocating(batch, mode_id, alloc_version)
        return true
    end)

    if not ok then
        return false
    end
    --创建房间不放入锁，因为获取房间需要花多一些时间
    --玩家可能在这里call出让cpu后,leave，那么我们回来还要检查alloc_canceled
    local ok, room_info = pcall(
        s.call,
        runconfig.roommgr.node,
        "roommgr",
        "create_room",
        batch,
        mode_id,
        alloc_version
    )
    --加协程锁,状态转移期间不处理leave和cancle和join
    local ok = state_lock(function()
        --开房间失败时，将状态未改变的玩家加回匹配队列
        --返回false,避免立刻重复拿同一批人继续开房导致死循环
        if not ok or not room_info then
            requeue_batch(batch, mode_id, alloc_version)
            return false
        end

        --如果这次分配被取消了，或者玩家状态变化了
        if alloc_canceled(batch, alloc_version) then
            --把还停留在 ROOM_ALLOCATING 的玩家回退回匹配队列
            requeue_batch(batch, mode_id, alloc_version)
            --清理这次的分配记录
            alloc_records[alloc_version] = nil
            --通知房间关闭
            s.send(room_info.room_node, room_info.room, "abort_room", "alloc canceled")
            return false
        end

        --转移玩家状态到room_preparing
        mark_batch_preparing(batch, room_info, alloc_version)

        notify_match_found(batch)
        return true
    end)
    return ok
end

--处理玩家的join请求
function s.resp.join(source, playerid, mode_id, rank_score, agent_node, agent)
    return state_lock(function()
        if shutting_down then
            return false, "server shutting down"
        end
        if not MATCH_CONFIG[mode_id] then
            return false, "mode_id不存在"
        end
        local cfg = MATCH_CONFIG[mode_id]
        local info = load_player_state(playerid)
        if info.state ~= STATE.IDLE then
            return false, "不要重复匹配"
        end
        --转移玩家状态到matching
        info.state = STATE.MATCHING
        info.mode_id = mode_id
        info.rank_score = rank_score
        info.segment_id = cal_segment(rank_score, cfg.segment_span)
        info.queue_enter_ms = now_ms()
        info.agent = agent
        info.agent_node = agent_node
        save_player_state(info)

        --玩家加到匹配队列
        rds:zadd(queue_key(mode_id, info.segment_id), info.queue_enter_ms, tostring(playerid))
        --更新活跃桶
        rds:sadd(active_segments_key(mode_id), tostring(info.segment_id))

        return true
    end)
end

--处理玩家的取消匹配请求
function s.resp.cancel(source, playerid)
    return state_lock(function()
        --只允许matching状态取消
        local info = load_player_state(playerid)
        if info.state == STATE.IDLE then
            return false, "当前不在匹配中"
        end
        if info.state ~= STATE.MATCHING then
            return false, "当前阶段不能取消匹配"
        end

        --从匹配队列删除
        rds:zrem(queue_key(info.mode_id, info.segment_id), tostring(playerid))
        --删除玩家匹配状态
        clear_player_state(playerid)
        return true
    end)
end

--处理查询玩家匹配状态
function s.resp.status(source, playerid)
    return true, load_player_state(playerid)
end

--处理玩家离开匹配或者房间
function s.resp.leave(source, playerid, reason)
    return state_lock(function()
        local info = load_player_state(playerid)
        if info.state == STATE.IDLE then
            clear_player_state(playerid)
            return true
        end

        if info.state == STATE.MATCHING then
            rds:zrem(queue_key(info.mode_id, info.segment_id), tostring(playerid))
            clear_player_state(playerid)
            return true
        end

        if info.state == STATE.ROOM_ALLOCATING then
            --标记这次分配取消
            if info.alloc_version then
                cancel_alloc(info.alloc_version)
            end
            clear_player_state(playerid)
            return true
        end

        if info.state == STATE.ROOM_PREPARING or info.state == STATE.RUNNING then
            if info.room and info.room_node then
                s.send(info.room_node, info.room, "leave", playerid, reason)
            end
            return true
        end
        return false
    end)
end
--停止匹配服务
function s.resp.shutdown()
    return state_lock(function()
        shutting_down = true

        for mode_id, cfg in pairs(MATCH_CONFIG) do
            --清除所有模式的匹配队列的玩家
            local raw_segments = rds:smembers(active_segments_key(mode_id)) or {}
            for _, raw_segment_id in ipairs(raw_segments) do
                local segment_id = tonumber(raw_segment_id)
                local qkey = queue_key(mode_id, segment_id)
                local ids = rds:zrange(qkey, 0, -1) or {}

                for _, raw_playerid in ipairs(ids) do
                    local playerid = tonumber(raw_playerid)
                    local info = load_player_state(playerid)
                    if info.state == STATE.MATCHING then
                        rds:zrem(qkey, raw_playerid)
                        clear_player_state(playerid)
                    end
                end
            end
        end
        return true
    end)
end

--删除所有redis中的匹配相关数据
local function clear_all_match_state()
    local patterns = {
        "match:player:*",
        "match:queue:*",
        "match:active_segment:*",
    }

    for _, pattern in ipairs(patterns) do
        local keys = rds:keys(pattern) or {}
        for _, key in ipairs(keys) do
            rds:del(key)
        end
    end

    alloc_version = 0
    alloc_records = {}
end

function s.init()
    rds = redis.connect({
        host = "127.0.0.1",
        port = 6379,
        auth = "123456",
    })

    clear_all_match_state()

    skynet.fork(function()
        while true do
            if not shutting_down then
                --遍历所有模式
                for mode_id in pairs(MATCH_CONFIG) do
                    while true do
                        local ok, matched = pcall(try_match, mode_id)
                        --凑不出玩家了
                        if not matched or not ok then
                            break
                        end
                    end
                end
            end
            skynet.sleep(SCAN_INTERVAL)
        end
    end)
end
s.start(...)
