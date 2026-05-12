local skynet = require("skynet")
local s = require("service")
local runconfig = require("runconfig")
local cjson = require("cjson")
local STATE = {
    IDLE = 0,
    MATCHING = 1,
    ROOM_ALLOCATING = 2,
    ROOM_PREPARING = 3,
    RUNNING = 4,
}

local mode_ids = { --存在的模式
    [1] = true,
}

--返回玩家匹配状态的redis key
local function player_key()
    return "match:player:" .. tostring(s.id)
end

--从redis加载玩家状态
local function load_match_state()
    local ret = { --默认状态
        state = STATE.IDLE,
        mode_id = nil, --客户端请求匹配状态时用
        --客户端发prepare时用
        room_node = nil,
        room = nil,
    }
    local raw = s.rds:get(player_key())
    if not raw then
        return ret
    end
    local data = cjson.decode(raw)

    ret.mode_id = data.mode_id
    ret.state = data.state
    ret.room = data.room
    ret.room_node = data.room_node

    return ret
end
--客户端匹配申请
function s.client.join_match(msg)
    local mode_id = msg.mode_id
    if mode_ids[mode_id] ~= true then
        return { "join_match", code = 1, msg = "不存在的模式" }
    end

    local info = load_match_state()

    if info.state ~= STATE.IDLE then
        return { "join_match", code = 1, msg = "不要重复匹配" }
    end

    local ok, err = s.call(
        runconfig.match.node,
        "match",
        "join",
        s.id,
        mode_id,
        s.data.base_info.rank_score,
        skynet.getenv("node"),
        skynet.self()
    )
    if not ok then
        return { "join_match", code = 1, msg = err or "匹配失败" }
    end
    return { "join_match", code = 0, msg = "匹配中" }
end

--客户端取消匹配
function s.client.cancel_match(msg)
    local ok, err = s.call(runconfig.match.node, "match", "cancel", s.id)
    if not ok then
        return { "cancel_match", code = 1, msg = err or "取消匹配失败" }
    end
    return { "cancel_match", code = 0, msg = "取消匹配成功" }
end

--客户端查询匹配状态
function s.client.match_status(msg)
    local info = load_match_state()

    return {
        "match_status",
        code = 0,
        msg = "查询成功",
        state = info.state,
        mode_id = info.mode_id,
    }
end

--客户端准备
function s.client.prepare(msg)
    local info = load_match_state()

    if info.state ~= STATE.ROOM_PREPARING then
        return { "prepare", code = 1, msg = "当前不在准备阶段" }
    end
    if not info.room or not info.room_node then
        return { "prepare", code = 1, msg = "房间不存在" }
    end
    local prepare_ok, err = s.call(info.room_node, info.room, "prepare", s.id)

    if not prepare_ok then
        return { "prepare", code = 1, msg = "准备失败" }
    end
    return { "prepare", code = 0, msg = "准备成功" }
end

--结算
function s.resp.battle_result(source, data)
    local weight_score = data.weight_score
    local score_delta = data.score_delta
    local coin = data.coin
    local exp = data.exp

    if score_delta ~= 0 then
        s.add_rank_score(score_delta)
    end
    if exp ~= 0 then
        s.add_exp(exp)
    end
    if coin ~= 0 then
        s.add_coin(coin)
    end

    skynet.send(s.gate, "lua", "send", s.id, {
        "battle_result",
        rank = data.rank,
        weight_score = weight_score,
        score_delta = score_delta,
        coin = coin,
        exp = exp,
    })
end

function s.leave_match_or_room()
    pcall(s.call, runconfig.match.node, "match", "leave", s.id, "agent kick")
end
--战斗网关超时断开的接口
function s.resp.battle_leave_room()
    s.leave_match_or_room()
end

function s.resp.can_shutdown_kick()
    local info = load_match_state()

    if
        info.state == STATE.ROOM_ALLOCATING
        or info.state == STATE.ROOM_PREPARING
        or info.state == STATE.RUNNING
    then
        return false
    end

    return true
end

s.start(...)
