local skynet = require("skynet")
local redis_client = require("redis_client")
local s = require("service")
local runconfig = require("runconfig")
local cjson = require("cjson")
local harbor = require("skynet.harbor")
local queue = require("skynet.queue")
local player_state_lock = queue()
local prepare_room_lock = queue()
local STATE = {
    IDLE = 0,
    MATCHING = 1,
    ROOM_ALLOCATING = 2,
    ROOM_PREPARING = 3,
    RUNNING = 4,
}

local ROOM_STATE = {
    UNINIT = 1, --未初始化
    WAIT_PREPARE = 2, --等待所有玩家的准备
    WAIT_BATTLE_PREPARE = 3, --等待所有kcp会话准备好
    RUNNING = 4,
    ABORTING = 5,
    FINISHING = 6,
    ABORTED = 7,
    FINISHED = 8,
}

local function empty_player_state(playerid)
    return {
        playerid = playerid,
        state = STATE.IDLE,
        mode_id = nil,
        room_node = nil,
        room_id = nil,
        room = nil, --skynet服务句柄
        scene_addr = nil,
        alloc_version = nil, --当前这次分房申请版本号
        agent_node = nil,
        agent = nil,
        rank_score = nil, --段位分
        segment_id = nil, --玩家当前所在的段位桶号
        queue_enter_ms = nil, --玩家匹配了多久
    }
end

local function player_key(playerid)
    return "match:player:" .. tostring(playerid)
end

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

local room_state = ROOM_STATE.UNINIT
local mode_id = 0
local alloc_version = 0
local scene_addr = nil
local battle_gateway = nil
local PREPARE_TIMEOUT_MS = 15 * 1000
local ROUND_DURATION_MS = 10 * 60 * 1000 --一局持续时间

local players = {} --[playerid]->player

local function now_ms()
    return skynet.now() * 10
end

--room中的玩家类,根据玩家基础信息构造
local function new_player(info)
    return {
        playerid = tonumber(info.playerid),
        agent = info.agent,
        agent_node = info.agent_node,
        prepared = false, --准备标志位
        battle_ready = false, --kcp会话准备好标志位
        alive = false, --玩家是否存活（指在场景中）
        in_room = true, --玩家是否在线（指限于在房间中，不管房间外）
        --结算信息
        rank = 0, --排名
        weight_score = 1,
        kill_count = 0,
        death_count = 0,
        alive_ms = 0,
        last_spawn_ms = 0, --上次复活时间，用于计算累计存活时间
        battle_conv = 0, --玩家kcp会话号
    }
end

--排序当前房间玩家列表
local function sorted_players()
    local arr = {}
    for _, p in pairs(players) do
        table.insert(arr, p)
    end
    table.sort(arr, function(a, b)
        return a.playerid < b.playerid
    end)
    return arr
end

--从redis读取玩家状态
local function load_player_state(playerid)
    playerid = tonumber(playerid)
    local raw = rds:get(player_key(playerid))
    if not raw then --用cjson解码nil,或者""会报错，这里直接返回默认
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

--设置redis中在本房间玩家的状态为running
local function set_players_running()
    return player_state_lock(function()
        for _, rp in pairs(players) do
            if rp.in_room then
                local state = load_player_state(rp.playerid)
                state.state = STATE.RUNNING
                save_player_state(state)
            end
        end
    end)
end
--带锁的清理玩家状态
local function clear_one_player_state(playerid)
    return player_state_lock(function()
        clear_player_state(playerid)
    end)
end
--带锁的清理所有在房间玩家状态
local function clear_inroom_player_state()
    return player_state_lock(function()
        for _, rp in pairs(players) do
            if rp.in_room then
                clear_player_state(rp.playerid)
            end
        end
    end)
end

local function notify_agent(player, cmd, ...)
    if not player or not player.agent or not player.agent_node then
        return
    end
    s.send(player.agent_node, player.agent, cmd, ...)
end

--构造玩家准备列表
local function build_prepare_players()
    local ret = {}
    for _, p in ipairs(sorted_players()) do
        table.insert(ret, {
            playerid = p.playerid,
            is_prepared = p.prepared,
        })
    end
    return ret
end

--向房间所有玩家广播准备状态
local function broadcast_prepared_players()
    local payload = {
        "room_prepare",
        players = build_prepare_players(),
    }
    for _, p in pairs(players) do
        notify_agent(p, "send", payload)
    end
end

--判断玩家是否全部按下准备按钮
local function all_prepared()
    for _, p in pairs(players) do
        if not p.prepared then
            return false
        end
    end
    return true
end
--判断玩家kcp会话是否全部准备好
local function all_battle_ready()
    for _, p in pairs(players) do
        if not p.battle_ready then
            return false
        end
    end
    return true
end

--统计房间里面在线的玩家数
local function inroom_player_count()
    local n = 0
    for _, p in pairs(players) do
        if p.in_room then
            n = n + 1
        end
    end
    return n
end
--选择一个战斗网关，轮询
local function pick_battle_gateway()
    local room_node = skynet.getenv("node")
    local cfg = runconfig[room_node].battle_gateway or {}
    assert(#cfg > 0, "battle_gateway empty")

    local idx = math.random(1, #cfg)
    return harbor.queryname("battle_gateway" .. idx)
end
--释放玩家的kcp会话
local function free_player_battle_session(player)
    if not player or not battle_gateway or player.battle_conv == 0 then
        return
    end
    local conv = player.battle_conv
    player.battle_conv = 0
    pcall(skynet.call, battle_gateway, "lua", "free", conv)
end

--通知scene关闭当前场景
local function shutdown_scene()
    if scene_addr then
        pcall(skynet.call, scene_addr, "lua", "shutdown_scene")
    end
end

local function notify_roommgr_close()
    pcall( --不要让通知roommgr失败影响room关闭
        s.send,
        runconfig.roommgr.node,
        "roommgr",
        "room_closed",
        skynet.getenv("node"),
        skynet.self()
    )
end

--设置房间终态，关闭scene,并且准备退出
local function close_room(final_state)
    room_state = final_state
    notify_roommgr_close()
    shutdown_scene()
    --延迟退出是为了让abort_room正常返回
    skynet.timeout(10, function()
        skynet.exit()
    end)
    return true
end

--根据排名计算段位分，金币和经验奖励
local function calc_reward(total_player, rank)
    if rank <= 0 then --不合法
        return 0, 0, 0
    end
    local win_count = math.ceil(total_player / 2)
    local score_delta
    if rank > win_count then --后半部分玩家减分
        score_delta = -(rank - win_count) * 10
    else --前半部分玩家加分
        score_delta = (win_count - rank + 1) * 10
    end
    local base = math.max(0, total_player - rank + 1)
    local coin = 10 + base * 10
    local exp = 5 + base * 8
    return score_delta, coin, exp
end

--异常结束房间，清除玩家状态，关闭会话，设置房间终态
local function abort_room(reason)
    if
        room_state == ROOM_STATE.ABORTING
        or room_state == ROOM_STATE.ABORTED
        or room_state == ROOM_STATE.FINISHING
        or room_state == ROOM_STATE.FINISHED
    then
        return true
    end
    room_state = ROOM_STATE.ABORTING
    clear_inroom_player_state()
    for _, p in pairs(players) do
        free_player_battle_session(p)
        notify_agent(p, "send", {
            "room_dismiss",
            reason = reason or "房间已解散",
        })
    end

    return close_room(ROOM_STATE.ABORTED)
end
--供外部调用，不清理玩家状态，外部必须负责玩家状态转移
local function abort_room_without_clear_state(reason)
    if
        room_state == ROOM_STATE.ABORTING
        or room_state == ROOM_STATE.ABORTED
        or room_state == ROOM_STATE.FINISHING
        or room_state == ROOM_STATE.FINISHED
    then
        return true
    end

    room_state = ROOM_STATE.ABORTING

    for _, p in pairs(players) do
        free_player_battle_session(p)
    end

    return close_room(ROOM_STATE.ABORTED)
end

--生成最终排名
local function build_rank_list()
    local arr = {}

    local now = now_ms()
    --对局结束时最后统计一次玩家存活时长
    for _, p in pairs(players) do
        if p.alive and p.last_spawn_ms ~= 0 then
            p.alive_ms = p.alive_ms + math.max(0, now - p.last_spawn_ms)
            p.last_spawn_ms = now
        end
        table.insert(arr, p)
    end

    --拉取玩家的体重数据
    local ok, stats = pcall(skynet.call, scene_addr, "lua", "get_weight")
    if ok and stats then
        for _, v in ipairs(stats) do
            local p = players[v.playerid]
            p.weight_score = math.floor(v.weight_score)
        end
    end

    table.sort(arr, function(a, b)
        if a.weight_score ~= b.weight_score then
            return a.weight_score > b.weight_score
        end
        return a.playerid < b.playerid
    end)
    for idx, p in ipairs(arr) do
        p.rank = idx
    end
    return arr
end

--结算
local function finish_room(reason)
    if
        room_state == ROOM_STATE.ABORTING
        or room_state == ROOM_STATE.ABORTED
        or room_state == ROOM_STATE.FINISHING
        or room_state == ROOM_STATE.FINISHED
    then
        return true
    end
    room_state = ROOM_STATE.FINISHING

    --排名
    local settled = build_rank_list()
    --计算奖励
    for _, p in ipairs(settled) do
        local score_delta, coin, exp = calc_reward(#settled, p.rank)
        notify_agent(p, "battle_result", {
            rank = p.rank,
            weight_score = p.weight_score,
            score_delta = score_delta,
            coin = coin,
            exp = exp,
        })

        free_player_battle_session(p)
    end
    clear_inroom_player_state()
    return close_room(ROOM_STATE.FINISHED)
end

--推进房间状态到RUNNING，修改玩家状态为running，设置玩家初始信息
local function start_running()
    room_state = ROOM_STATE.RUNNING
    local ok = skynet.call(scene_addr, "lua", "start_game")

    if room_state ~= ROOM_STATE.RUNNING then
        --回来后有可能玩家leave导致finish_room
        --这里判断一下防止把已经清掉的玩家redis状态写回来
        return false
    end
    if not ok then
        abort_room("start_game失败")
        return false
    end

    set_players_running()

    for _, rp in pairs(players) do
        --只设置在房间的玩家的信息
        --开始时设置上次复活时间为now
        if rp.in_room then
            rp.alive = true
            rp.last_spawn_ms = now_ms()
        end
    end
    --结算定时器
    skynet.fork(function()
        --除10是因为skynet10ms最小单位
        skynet.sleep(math.max(1, math.ceil(ROUND_DURATION_MS / 10)))

        if room_state == ROOM_STATE.RUNNING then
            finish_room("对局结束")
        end
    end)
    return true
end

--记录玩家的一次死亡/击杀
local function on_player_dead(dead_playerid, killer_playerid)
    local dead = players[dead_playerid]
    local killer = players[killer_playerid]
    if not dead or not killer or killer_playerid == dead_playerid then
        return false
    end
    local now = now_ms()

    --更新一下玩家的存活时间
    if dead.alive and dead.last_spawn_ms > 0 then
        --这个dead玩家之前必须是活的
        dead.alive_ms = dead.alive_ms + math.max(0, now - dead.last_spawn_ms)
        dead.alive = false
        dead.last_spawn_ms = 0
        dead.death_count = dead.death_count + 1
        killer.kill_count = killer.kill_count + 1
    end
    return true
end

--记录一次玩家复活.设置玩家状态为alive
local function on_player_respawn(playerid)
    local p = players[playerid]
    if not p or not p.in_room then
        --对于离开房间的玩家，我们不能恢复alive
        --前面记录死亡。击杀可以，但是这个不行，因为这个是设置状态，不是计数
        return false
    end
    p.alive = true
    p.last_spawn_ms = now_ms()
    return true
end

--把running阶段离开的玩家标记为离开并视情况提前结算
local function mark_player_leaveroom(playerid, reason)
    local p = players[playerid]
    if not p then
        return false
    end
    if not p.in_room then
        return true
    end
    p.in_room = false
    clear_one_player_state(playerid)
    --玩家离开视作立即死亡
    --累加存活时间
    if p.alive and p.last_spawn_ms > 0 then
        p.alive_ms = p.alive_ms + now_ms() - p.last_spawn_ms
    end

    p.alive = false
    p.battle_ready = false
    p.last_spawn_ms = 0
    --通知战斗网关释放会话
    free_player_battle_session(p)
    --通知scene踢掉该玩家
    pcall(skynet.call, scene_addr, "lua", "kick_player", playerid)
    --确保回来后房间还是running状态，避免重复结算
    if room_state == ROOM_STATE.RUNNING and inroom_player_count() <= 1 then
        finish_room(reason)
    end
    return true
end

--分配会话期间用协程锁保护，不处理leave的remove_preparing_player，leave会释放会话导致并发问题
--另外abort_room也会释放会话，但是在这个阶段本地的abort_room只有remove_preparing_player里面的可能执行，这个用协程锁串行了
--外部的abort_room：match的分配取消时才会调用。
--这时候玩家的状态不会被转移到room_preparing，
--所以，agent那边不会转发准备消息，room这边不会进入WAIT_BATTLE_READY
--另外两个就是roommgr 预热room失败时会abortroom，，处于初始化失败阶段，也不会进入WAIT_BATTLE_READY
--缩紧房间池时会abortroom，关闭空闲房间，处于初始化阶段，同样不会进入WAIT_BATTLE_READY
--分配会话并且加入场景的无锁版本
local function alloc_battle_for_all_no_lock()
    --为玩家们申请会话
    if room_state ~= ROOM_STATE.WAIT_BATTLE_PREPARE then
        return false, "battle alloc cancled"
    end

    battle_gateway = pick_battle_gateway()

    --请求战斗网关批量分配会话
    local req = {}
    for _, p in pairs(players) do
        if p.in_room then
            table.insert(req, {
                playerid = p.playerid,
                agent_node = p.agent_node,
                agent = p.agent,
            })
        end
    end

    local battle_infos =
        skynet.call(battle_gateway, "lua", "batch_alloc", skynet.self(), scene_addr, req)

    if not battle_infos then
        return false, "battle_gateway batch_alloc失败"
    end

    --玩家批量加入场景
    local scene_players = {}
    for _, battle_info in ipairs(battle_infos) do
        local playerid = battle_info.playerid
        local p = players[playerid]

        p.battle_conv = battle_info.conv
        p.battle_ready = false

        scene_players[#scene_players + 1] = {
            playerid = p.playerid,
            battle_conv = battle_info.conv,
        }
    end

    local ok, ret =
        pcall(skynet.call, scene_addr, "lua", "batch_add_player", scene_players, battle_gateway)
    if not ok or not ret then
        for _, info in ipairs(battle_infos) do
            local p = players[info.playerid]
            free_player_battle_session(p)
        end
        return false, "scene batch_add_player失败"
    end

    --向所有客户端通知战斗链路信息
    for _, battle_info in ipairs(battle_infos) do
        local p = players[battle_info.playerid]
        notify_agent(p, "send", {
            "battle_connect",
            battle_host = battle_info.host,
            battle_port = battle_info.port,
            battle_conv = battle_info.conv,
            battle_token = battle_info.token,
        })
    end
    return true
end
local function alloc_battle_for_all()
    return prepare_room_lock(alloc_battle_for_all_no_lock)
end

--把准备阶段的玩家踢出房间，并且判断是否还能继续
local function remove_preparing_player(playerid, reason)
    return prepare_room_lock(function()
        local p = players[playerid]
        if not p then
            return false
        end
        players[playerid] = nil

        --清理玩家状态
        clear_one_player_state(playerid)

        --清理玩家会话
        free_player_battle_session(p)

        --把玩家从场景移除
        pcall(skynet.call, scene_addr, "lua", "kick_player", playerid)

        --广播最新玩家准备状态
        broadcast_prepared_players()
        --判断是否应该解散
        if inroom_player_count() < 2 then
            return abort_room(reason or "prepare player not enough")
        end
        --判断是否可以转移到wait_battle_ready状态
        if room_state == ROOM_STATE.WAIT_PREPARE and all_prepared() then
            room_state = ROOM_STATE.WAIT_BATTLE_PREPARE
            local ok, err = alloc_battle_for_all_no_lock()

            if not ok then
                abort_room(err or "分配battle链路失败")
                return false, err
            end
            return true
        end
        --判断是否可以开始,状态转移前要判断状态，避免aborted状态转为running
        if room_state == ROOM_STATE.WAIT_BATTLE_PREPARE and all_battle_ready() then
            return start_running()
        end

        return true
    end)
end

--预热room服务，创建scene服务
function s.resp.prewarm(source, arg_mode_id, scene_code_name)
    if room_state ~= ROOM_STATE.UNINIT then
        return false
    end
    if scene_addr then
        return {
            scene_addr = scene_addr,
        }
    end
    mode_id = arg_mode_id
    --启动场景服务
    --如果以后要扩展其他模式，这里可以启动不同的scene服务
    --比如scene1,scene2
    scene_addr = s.call(
        skynet.getenv("node"),
        "nodemgr",
        "newservice",
        scene_code_name,
        scene_code_name,
        s.id,
        arg_mode_id,
        skynet.self()
    )
    if not scene_addr then
        return false
    end
    return {
        scene_addr = scene_addr,
    }
end

--初始化room服务，创建scene服务，转移状态到wait_prepare
function s.resp.init_room(source, room_id, player_list, arg_alloc_version)
    if room_state ~= ROOM_STATE.UNINIT then
        return false
    end
    if not scene_addr then
        return false
    end

    alloc_version = arg_alloc_version
    room_state = ROOM_STATE.WAIT_PREPARE

    --初始化玩家信息
    for _, info in ipairs(player_list) do
        players[info.playerid] = new_player(info)
    end

    --启动一个准备定时器
    skynet.fork(function()
        skynet.sleep(math.max(1, math.floor(PREPARE_TIMEOUT_MS / 10)))
        if room_state ~= ROOM_STATE.WAIT_PREPARE then
            return
        end
        if all_prepared() then
            return
        end
        abort_room("有玩家未准备")
    end)

    return {
        scene_addr = scene_addr,
    }
end

--玩家准备
function s.resp.prepare(source, playerid)
    if room_state == ROOM_STATE.UNINIT then
        return false, "房间尚未初始化"
    end
    if room_state ~= ROOM_STATE.WAIT_PREPARE then
        return false, "房间不在准备阶段"
    end

    local p = players[playerid]
    if not p then
        return false, "玩家不在房间"
    end
    if p.prepared then
        return true
    end

    p.prepared = true
    broadcast_prepared_players()

    if all_prepared() then
        room_state = ROOM_STATE.WAIT_BATTLE_PREPARE
        local ok, err = alloc_battle_for_all()
        if not ok then
            abort_room(err or "分配battle链路失败")
            return false, err
        end
    end
    return true
end

--战斗网关的kcp会话准备好/断线
function s.resp.battle_ready(source, playerid, conv, ready)
    local p = players[playerid]
    --玩家退出
    if not p then
        return false
    end
    if battle_gateway ~= source then
        return false
    end
    if p.battle_conv ~= conv then
        return false
    end
    p.battle_ready = ready
    --告知场景服务kcp会话的状态
    skynet.send(scene_addr, "lua", "battle_online", playerid, p.battle_ready)

    if room_state == ROOM_STATE.WAIT_BATTLE_PREPARE then
        if all_prepared() and all_battle_ready() then
            return start_running()
        end
    end
    return true
end

--接受scene上报的击杀/死亡事件
function s.resp.scene_player_dead(source, playerid, killer_playerid)
    if room_state ~= ROOM_STATE.RUNNING then
        --只有running状态才接受上报
        return true
    end
    return on_player_dead(playerid, killer_playerid)
end

--接受上报的复活事件
function s.resp.scene_player_respawn(source, playerid)
    if room_state ~= ROOM_STATE.RUNNING then
        return true
    end
    return on_player_respawn(playerid)
end

--玩家离开房间
function s.resp.leave(source, playerid, reason)
    local p = players[playerid]
    if not p then
        return true
    end
    if room_state == ROOM_STATE.WAIT_BATTLE_PREPARE or room_state == ROOM_STATE.WAIT_PREPARE then
        return remove_preparing_player(playerid, reason or "准备阶段有人离开")
    end
    if room_state == ROOM_STATE.RUNNING then
        return mark_player_leaveroom(playerid, reason or "玩家离开房间")
    end
    return false
end

function s.resp.abort_room(source, reason)
    return abort_room_without_clear_state(reason or "room abort")
end

s.init = function()
    rds = redis_client.connect()
end

s.start(...)
