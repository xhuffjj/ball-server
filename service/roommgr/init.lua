local skynet = require("skynet")
local s = require("service")
local runconfig = require("runconfig")
local redis = require("skynet.db.redis")
--房间分配号放redis里面
local function next_room_id_key()
    return "next:next_room_id"
end

local rds
local next_node_idx = 0

local ROOM_NODES = runconfig.room_nodes

local POOL_STATE = {
    IDLE = 1, --空闲状态
    RESERVED = 2, --被预定
    BUSY = 3,
    DEAD = 4,
}
--模式id->场景代码名
local MODE_SCENE_SERVICE = {
    [1] = "scene",
    [2] = "scene",
}

local POOL_MIN_IDLE = 2
local POOL_MAX_IDLE = 8
local POOL_IDLE_TTL = 30 * 100 --30s最大多余空闲房间=生存时间
local POOL_CHECK_INTERVAL = 100
--[mode_id]->对应模式的补池协程是否在运行
local refill_running = {}
--按照模式id分池
local room_pool = {}

local function pool_key(room_node, room)
    return tostring(room_node) .. ":" .. tostring(room)
end

local function count_idle_room(mode_id)
    local n = 0
    for _, v in pairs(room_pool[mode_id] or {}) do
        if v.state == POOL_STATE.IDLE then
            n = n + 1
        end
    end
    return n
end

local function find_idle_room(mode_id)
    for _, v in pairs(room_pool[mode_id] or {}) do
        if v.state == POOL_STATE.IDLE then
            return v
        end
    end
end

local function reserve_idle_room(mode_id)
    local entry = find_idle_room(mode_id)
    if entry then
        entry.state = POOL_STATE.RESERVED
    end
    return entry
end

local function remove_pool_room(entry)
    if not entry then
        return
    end
    entry.state = POOL_STATE.DEAD
    room_pool[entry.mode_id][pool_key(entry.room_node, entry.room)] = nil
end

local function close_idle_room(entry, reason)
    if not entry then
        return
    end
    remove_pool_room(entry)
    pcall(s.send, entry.room_node, entry.room, "abort_room", reason or "room pool shrink")
end
--轮询选择一个节点
local function pick_room_node()
    next_node_idx = next_node_idx + 1
    return ROOM_NODES[next_node_idx % #ROOM_NODES + 1]
end

local function create_idle_room_once(mode_id)
    if not MODE_SCENE_SERVICE[mode_id] then
        return false
    end
    local room_id = tonumber(rds:incr(next_room_id_key()))
    local room_node = pick_room_node()

    room_pool[mode_id] = room_pool[mode_id] or {}
    --在别的节点启动前创建服务会失败,我们用pcall包住忽略这个错误
    local ok, room = pcall(s.call, room_node, "nodemgr", "newservice", "room", "room", room_id)

    if not ok or not room then
        return false
    end

    local ok, room_info =
        --让房间创建场景服务，预热房间
        pcall(s.call, room_node, room, "prewarm", mode_id, MODE_SCENE_SERVICE[mode_id])
    if not ok or not room_info or not room_info.scene_addr then
        pcall(s.call, room_node, room, "abort_room", "prewarm_room failed")
        return false
    end

    local entry = {
        room_id = room_id,
        room_node = room_node,
        room = room,
        scene_addr = room_info.scene_addr,
        state = POOL_STATE.IDLE,
        idle_at = skynet.now(),
        mode_id = mode_id,
    }
    room_pool[mode_id][pool_key(room_node, room)] = entry
    return true
end

local function start_refill_pool(mode_id)
    if refill_running[mode_id] then
        return
    end
    refill_running[mode_id] = true
    skynet.fork(function()
        local ok, err = pcall(
            function(...) ---防止create_idle_room_once抛错导致refill_running[mode_id]无法被恢复为false
                while count_idle_room(mode_id) < POOL_MIN_IDLE do
                    if not create_idle_room_once(mode_id) then
                        break --避免死循环
                    end
                end
            end
        )
        if not ok then
            skynet.error(err)
        end
        refill_running[mode_id] = false
    end)
end

local function shrink_pool(mode_id)
    local idle_count = count_idle_room(mode_id)
    if idle_count <= POOL_MAX_IDLE then
        return
    end
    local now = skynet.now()
    for _, entry in pairs(room_pool[mode_id] or {}) do
        if idle_count <= POOL_MAX_IDLE then
            break
        end
        if entry.state == POOL_STATE.IDLE and now > entry.idle_at + POOL_IDLE_TTL then
            close_idle_room(entry, "room pool idle too many")
            idle_count = idle_count - 1
        end
    end
end

local function maintain_pool()
    for mode_id in pairs(MODE_SCENE_SERVICE) do
        start_refill_pool(mode_id)
        shrink_pool(mode_id)
    end
end

local function start_pool_timer()
    skynet.fork(function()
        while true do
            maintain_pool()
            skynet.sleep(POOL_CHECK_INTERVAL)
        end
    end)
end

--创建房间
function s.resp.create_room(source, player_list, mode_id, alloc_version)
    local entry = reserve_idle_room(mode_id)

    if not entry then
        --池子空了尝试开后台补池协程
        start_refill_pool(mode_id)
        return false
    end

    local ok = pcall(
        s.call,
        entry.room_node,
        entry.room,
        "init_room",
        entry.room_id,
        player_list,
        alloc_version
    )
    if not ok then
        --去掉失败房间
        remove_pool_room(entry)
        pcall(s.call, entry.room_node, entry.room, "abort_room", "init_room failed")
        --少了一个房间，尝试启动补池
        start_refill_pool(mode_id)
        return false
    end

    entry.state = POOL_STATE.BUSY
    --尝试补充空闲房间
    start_refill_pool(mode_id)
    return {
        room_id = entry.room_id,
        room_node = entry.room_node,
        room = entry.room,
        scene_addr = entry.scene_addr,
    }
end
--room主动退出时通知池子清理本room记录
function s.resp.room_closed(source, room_node, room)
    local key = pool_key(room_node, room)
    for mode_id, pool in pairs(room_pool) do
        if pool[key] then
            remove_pool_room(pool[key])
            --尝试补池子
            start_refill_pool(mode_id)
            break
        end
    end
end

local function check_room_nodes()
    assert(type(ROOM_NODES) == "table", "runconfig.room_nodes must be table")
    assert(#ROOM_NODES > 0, "runconfig.room_nodes empty")

    for _, node in ipairs(ROOM_NODES) do
        assert(type(node) == "string" and node ~= "", "invalid room node")
    end
end

-- 初始化 roommgr 的 Redis 连接。
s.init = function()
    rds = redis.connect({
        host = "127.0.0.1",
        port = 6379,
        auth = "123456",
    })
    check_room_nodes()
    start_pool_timer()
end

s.start(...)
