local skynet = require("skynet")
local s = require("service")
local Quadtree = require("quadtree")
local Cell = require("cell")
local Spore = require("spore")
local SceneEat = require("scene_eat")
local SceneSplit = require("scene_split")
local SceneCollision = require("scene_collision")
local GridIndex = require("grid_index")



local client = {}
local room=nil
local mode_id=nil
local game_started=false
local battle_gateway=nil
--记录离开场景的玩家的最后的重量
local left_weights={}
-----------配置数据----------------
local SCENE_WIDTH = 1000
local SCENE_HIGH = 1000
local SCENE_BOUNDS = { x = 0, y = 0, width = SCENE_WIDTH, height = SCENE_HIGH }
local SPLIT_FRICTION = 0.85
local FOOD_MAX = 4000
local PROTECTED_TIME=100
local GRID_SIZE = 32
local AOI_WIDTH = 320
local AOI_HEIGHT = 180
local AOI_PADDING = 16--屏幕外留半个格子的广播区域

local AOI_HALF_W = AOI_WIDTH * 0.5 + AOI_PADDING
local AOI_HALF_H = AOI_HEIGHT * 0.5 + AOI_PADDING
----------游戏数据---------------
local players = {}
local foods = {}
local spores = {}
local food_count = 0 --用于限制食物总数
local food_maxid = 0 --每创建一个食物就加一,食物标识符
local food_tree = Quadtree.new(SCENE_BOUNDS, 10, 5)
local spore_grid = GridIndex.new(SCENE_BOUNDS,GRID_SIZE)
local cell_grid = GridIndex.new(SCENE_BOUNDS,GRID_SIZE)
local dead_food_in_tree = { count = 0 }

------------工具函数--------------
local function new_player(playerid, battle_conv)
    local m = {
        playerid = playerid,
        battle_conv=battle_conv,--当前玩家的会话号
        --网关句柄+会话号可以唯一标识一个本节点的会话，我们根据这两个键联合，区分同一玩家的新旧会话
        --避免新旧会话的free/ready影响对方
        battle_online=false,--标志客户端kcp是否断开，true为未断开
        cells = {},
        target_x = 0,
        target_y = 0,
        moving=false,
        last_input_seq = 0, --客户端的每帧的输入指令集会带有这个递增的序列号，
        --服务器move广播里带上这个告诉客户端当前处理到哪了，
        --用于客户端预测的基准
        pending_actions = {}, --有待处理的split指令或者spit指令
    }
    return m
end

local function cell_count(player)
    local n = 0
    for _ in pairs(player.cells) do
        n = n + 1
    end
    return n
end

local function new_food()
    local m = {
        x = math.random(0, SCENE_WIDTH),
        y = math.random(0, SCENE_HIGH),
        id = nil,
    }
    return m
end

--计算视野矩型的中心，返回左上右下坐标
local function calc_player_aoi_rect(player)
    local sum_weight = 0
    local weighted_x = 0
    local weighted_y = 0

    for _, cell in pairs(player.cells) do
        local weight = math.max(1, cell.size * cell.size)
        sum_weight = sum_weight + weight
        weighted_x = weighted_x + cell.x * weight
        weighted_y = weighted_y + cell.y * weight
    end

    -- 没有球时直接返回空矩形，避免除 0。
    if sum_weight <= 0 then
        return -1, -1, -1, -1
    end
    --中心按照所有球的重量加权平均
    local center_x = weighted_x / sum_weight
    local center_y = weighted_y / sum_weight

   
    local min_x = center_x - AOI_HALF_W
    local max_x = center_x + AOI_HALF_W
    local min_y = center_y - AOI_HALF_H
    local max_y = center_y + AOI_HALF_H


    return min_x, min_y, max_x, max_y
end
--调用战斗网关释放会话
--[[local function free_battle_session(player)
    if not player or not battle_gateway or not player.battle_conv then
        return
    end
    
    skynet.call(battle_gateway,"lua","free",player.battle_conv)
end]]
--通知战斗网关send
local function send_frame_msg(player,msg)
    if not player or not player.battle_online or not battle_gateway then
        return false
    end
    skynet.send(battle_gateway,"lua","send",player.playerid,msg)
    return true
end

--[[随机选择本节点一个战斗网关
local function random_battle_gateway()
    local node=skynet.getenv("node")
    local cfg=runconfig[node].battle_gateway or {}
    local ids={}
    for i,_ in pairs(cfg) do
        table.insert(ids,i)
    end
    if #ids == 0 then
        return nil
    end
    local idx=ids[math.random(1,#ids)]
    --返回skynet句柄
    return assert(harbor.queryname("battle_gateway" .. idx))

end]]
--广播
local function broadcast_to_others(exclude_playerid, msg)
    for pid, player in pairs(players) do
        if pid ~= exclude_playerid then
            send_frame_msg(player, msg)
        end
    end
end

local function calc_player_weight_score(player)
    local total_mass = 0
    for _, cell in pairs(player.cells) do
        total_mass = total_mass + Cell.cal_mass(cell.size)
    end
    return math.floor(total_mass)
end

local frame = 0
--玩家进入和离开时的队列，在每一帧统一处理
local pending_enters = {}
local pending_leaves = {}
--重生队列
local pending_rebirth = {}

--返回玩家感兴趣区域的小球和孢子的快照消息表
local function build_player_visible_snapshot(player)
    --获取aoi矩形
    local min_x,min_y, max_x, max_y =calc_player_aoi_rect(player)
    --查询
    local visible_cells=cell_grid:queryRect(min_x,min_y, max_x, max_y)
    local visible_spores=spore_grid:queryRect(min_x,min_y, max_x, max_y)

    --排序
    table.sort(visible_cells, function(a, b)
        return a.id < b.id
    end)
    table.sort(visible_spores, function(a, b)
        return a.id < b.id
    end)

    --构建消息并返回
    local cell_snapshot={}
    local spore_snapshot={}

    for _, cell in ipairs(visible_cells) do
        table.insert(cell_snapshot, {
            cell_id = cell.id,
            x = cell.x,
            y = cell.y,
            size = cell.size,
            playerid = cell.playerid,
            protected_timer = cell.protected_timer,
        })
    end
    for i, v in ipairs(visible_spores) do
        table.insert(spore_snapshot, { spore_id = v.id, x = v.x, y = v.y})
    end

    return cell_snapshot,spore_snapshot
end

local function snapshot_msg(player)
    --小球和孢子只取感兴趣区域
    local cells_msg,spores_msg = build_player_visible_snapshot(player)
    
    local foods_msg = {}
    for i, v in pairs(foods) do
        table.insert(foods_msg, { id = v.id, x = v.x, y = v.y })
    end


    return { "scene_snapshot", cells = cells_msg, spores = spores_msg, foods = foods_msg ,tick=frame,}
end


function s.resp.client(source,playerid,cmd,msg)
    if client[cmd] then
        local ret_msg = client[cmd](playerid,msg, source)
        if ret_msg then -- 只有在有返回消息时才发送
            send_frame_msg(players[playerid],ret_msg)
        end
    else
        skynet.error("s.resp.client failed: " .. cmd)
    end
end

--玩家加入，小球进入enter队列
--[[function s.resp.enter(source, playerid, node, agent)
    if players[playerid] or pending_enters[playerid] then --不可重复加入
        return false
    end

    local battle_gateway=random_battle_gateway()
    if not battle_gateway then
        return false
    end
    
    local battle_info= skynet.call(battle_gateway,"lua","alloc",playerid,skynet.self(),node,agent)
    if not battle_info then
        return false
    end

    local p = new_player(playerid, node, agent)
    p.battle_gateway=battle_gateway
    p.battle_conv=battle_info.conv

    local c = Cell.new(playerid, math.random(0, SCENE_WIDTH), math.random(0, SCENE_HIGH), 1)
    c.protected_timer=PROTECTED_TIME
    p.cells[c.id] = c
    pending_enters[playerid] = p

    return true,battle_info
end]]
--玩家批量加入
function s.resp.batch_add_player(source,player_list,arg_battle_gateway)
    battle_gateway=arg_battle_gateway

    for _,info in ipairs(player_list or {}) do
        local playerid=info.playerid
        if players[playerid] or pending_enters[playerid] then
            --不可重复加入
            return false
        end
    end

    for _,info in ipairs(player_list or {}) do
        local playerid=info.playerid
        local p=new_player(playerid,info.battle_conv)
        local c = Cell.new(playerid, math.random(0, SCENE_WIDTH), math.random(0, SCENE_HIGH), 1)
        c.protected_timer=PROTECTED_TIME
        p.cells[c.id] = c
        pending_enters[playerid] = p
    end
    return true
end
--设置玩家准备好接受数据
--[[function s.resp.battle_ready(source,conv,playerid,ready)
    local p= pending_enters[playerid] or players[playerid]
    --pending_enters代表第一次准备，players[playerid]代表是断线重连
    if not p then
        return false
    end

    --判断这个会话是否还是之前那次enter申请的会话，因为有可能顶号后再enter会给该玩家再申请一个新会话
    --网关句柄+conv唯一标识一个会话
    --如果这个发准备好的会话已被弃用，直接返回false，不要让它影响当前会话
    if source~=p.battle_gateway then
        return false
    end
    if conv~=p.battle_conv then
        return false
    end

    p.battle_ready=ready
    return true
end]]
--标记玩家是否掉线
function s.resp.battle_online(source,playerid,online)
    local p=pending_enters[playerid] or players[playerid]
    --pending_enters代表第一次准备，players[playerid]代表是断线重连
    if not p then
        return false
    end

    p.battle_online=online
    return true
end
--标记开始游戏
function s.resp.start_game()
    game_started = true
    return true
end
--发一份场景快照
function s.resp.battle_resync(source,playerid,conv)
    local p=  players[playerid]

    if not p then
        return false
    end

    if source~=battle_gateway then
        return false
    end
    if conv~=p.battle_conv then
        return false
    end

    send_frame_msg(p,snapshot_msg(p))
    return true
end

--玩家离开，玩家进入删除队列
function s.resp.kick_player(source, playerid)
    if pending_enters[playerid] then
        pending_enters[playerid] = nil
        return true
    end
    if pending_rebirth[playerid] then
        left_weights[playerid]=1
        pending_rebirth[playerid]=nil
        pending_leaves[playerid] = true
        return true
    end
    if not players[playerid] or pending_leaves[playerid]then
        return false
    end
    left_weights[playerid]=calc_player_weight_score(players[playerid])
    pending_leaves[playerid] = true
    return true
end

--统一删除玩家
local function flush_pending_leaves()
    for playerid,_ in pairs(pending_leaves) do 
        if players[playerid] then
            for _, cell in pairs(players[playerid].cells) do
                -- 玩家整个人离场时，把他的所有小球都从网格删掉。
                cell_grid:remove(cell)
            end
            players[playerid] = nil
            --广播离开玩家
            broadcast_to_others(playerid, {
                "leave_notify",
                playerid = playerid,
            })
        end
        pending_leaves[playerid] = nil
       
    end
end

--统一新增玩家
local function flush_pending_enters()
    for playerid, p in pairs(pending_enters) do
        if not game_started then
            goto continue
        end
        players[playerid] = p
        --加入网格
        for _, cell in pairs(p.cells) do
            cell_grid:add(cell)
        end
        --广播新玩家
        broadcast_to_others(playerid, {
            "enter_notify",
            playerid = playerid,
        })

        --回送战场信息
        send_frame_msg(p,snapshot_msg(p))

        pending_enters[playerid] = nil
        ::continue::
    end
end
--统一复活玩家
local function flush_pending_rebirth()
    for playerid ,p in pairs(pending_rebirth) do
        local x,y=math.random(0, SCENE_WIDTH),math.random(0, SCENE_HIGH)
        local c=Cell.new(playerid, x, y, 1)

        c.protected_timer=PROTECTED_TIME
        p.cells[c.id]=c
        p.target_x,p.target_y=x,y
        p.moving=false

        cell_grid:add(c)

        skynet.send(room,"lua","scene_player_respawn",playerid)
        pending_rebirth[playerid]=nil
    end
end
--改变方位,保存split，spit，下一帧统一处理
function client.input_frame(playerid, msg)
    if not players[playerid] then
        return
    end
    local target_x = msg.target_x or 0
    local target_y = msg.target_y or 0
    local moving=msg.moving;
    local input_seq = msg.input_seq or 0
    local split=msg.split
    local spit=msg.spit
    local p = players[playerid]
    if input_seq and input_seq <= p.last_input_seq then--拒绝旧指令
        return
    end
    
    if moving then
        -- 保存目标点
        p.target_x = target_x
        p.target_y = target_y

        for _,cell in pairs(p.cells) do
            local dx=target_x-cell.x
            local dy=target_y-cell.y
            local dist=math.sqrt(dx*dx+dy*dy)
            if dist>0.001 then
                cell.last_dir_x=dx/dist
                cell.last_dir_y=dy/dist
            end
            --dist如果太小，比如和目标点重合，那即使moving为true,我们也不改last_dir_了
        end
        p.moving=true
    else
        p.moving=false
    end

    
    local seq = input_seq or p.last_input_seq
    if split then
        local action={
            kind="split",
            target_x=target_x,target_y=target_y,--快照记录目标点，防止后面moving为true的帧更新目标点
            seq = seq,
            moving=moving,--moving为false时，分裂看last_dir_,不看target_
            cell_dirs={}--记录此输入帧每个子球的last_dir_,因为last_dir有可能被moving为true的输入帧更新
        }
        
        for _, cell in pairs(p.cells) do
            action.cell_dirs[cell.id] = {
            last_dir_x = cell.last_dir_x,
            last_dir_y = cell.last_dir_y,
            }
        end
        table.insert(p.pending_actions,action)
    end
    
    if spit then
        local action={
            kind="spit",
            target_x=target_x,target_y=target_y,--快照记录目标点，防止后面moving为true的帧更新目标点
            seq = seq,
            moving=moving,--moving为false时，分裂看last_dir_,不看target_
            cell_dirs={}--记录此输入帧每个子球的last_dir_,因为last_dir有可能被moving为true的输入帧更新
        }
        
        for _, cell in pairs(p.cells) do
            action.cell_dirs[cell.id] = {
            last_dir_x = cell.last_dir_x,
            last_dir_y = cell.last_dir_y,
            }
        end
        table.insert(p.pending_actions,action)
    end
    p.last_input_seq = seq --收到输入帧更新一下最新收到的序列号
    return
end

--每帧更新------------------------------
local function food_update(frame_event)
    if food_count >= FOOD_MAX then
        return
    end
    if math.random(0, 99) < 50 then
        return
    end
    food_count = food_count + 1
    food_maxid = food_maxid + 1
    local f = new_food()
    food_tree:insert(f) --增量更新
    f.id = food_maxid
    foods[food_maxid] = f
    table.insert(frame_event.new_foods, { id = f.id, x = f.x, y = f.y })
end

local function spores_move()
    for _, spore in pairs(spores) do
        Spore.update(spore, SCENE_WIDTH, SCENE_HIGH)
        --新孢子add，老孢子更新格子范围
        spore_grid:upsert(spore)
    end
end

local function cell_move()
    for pid, player in pairs(players) do
        for cid, cell in pairs(player.cells) do
            if player.moving then
                --计算方向
                local dx = player.target_x - cell.x
                local dy = player.target_y - cell.y
                local dist = math.sqrt(dx * dx + dy * dy)
                if dist>0.001 then
                    local dir_x = dx / dist
                    local dir_y = dy / dist
                    --计算速度
                    local speed = Cell.calc_speed(cell.size)
                    --如果speed*0.2大于step，就只走到目标点
                    cell.x = cell.x + dir_x * math.min(speed * 0.2,dist)
                    cell.y = cell.y + dir_y * math.min(speed * 0.2,dist)

                    cell.last_dir_x=dir_x
                    cell.last_dir_y = dir_y
                end
                --如果dist<=0.001，可以认为重合了，不走了
            end
                 
            --弹射位移
            if cell.boost_vx ~= 0 or cell.boost_vy ~= 0 then
                cell.x = cell.x + cell.boost_vx * 0.2
                cell.y = cell.y + cell.boost_vy * 0.2
                cell.boost_vx = cell.boost_vx * SPLIT_FRICTION
                cell.boost_vy = cell.boost_vy * SPLIT_FRICTION
                if math.abs(cell.boost_vx) < 0.01 then
                    cell.boost_vx = 0
                end
                if math.abs(cell.boost_vy) < 0.01 then
                    cell.boost_vy = 0
                end
            end
            --边界
            cell.x = math.max(0, math.min(SCENE_WIDTH, cell.x))
            cell.y = math.max(0, math.min(SCENE_HIGH, cell.y))

            --新球add,老球更新格子范围
            cell_grid:upsert(cell)
        end
    end
end

local function eat_food(frame_event)
    local event = SceneEat.eat_food(players, foods, food_tree, dead_food_in_tree,cell_grid)
    for _, e in ipairs(event) do
        food_count = food_count - 1
        table.insert(frame_event.eaten_food_ids, e.food.id)
    end
end

local function eat_spore()
    local event = SceneEat.eat_spore(players, spores, spore_grid,cell_grid)
end

local function eat_cell(frame_event)
    local event = SceneEat.eat_player(players, cell_grid)
    for _, e in ipairs(event) do
        local dead_cell_player = players[e.dead_cell_playerid]
        if dead_cell_player and cell_count(dead_cell_player) == 0 then
            --准备重生
            pending_rebirth[e.dead_cell_playerid] = dead_cell_player
            table.insert(frame_event.dead_playerids, e.dead_cell_playerid)
            skynet.send(room,"lua","scene_player_dead",e.dead_cell_playerid,e.eater.playerid)
        end
    end
end

local function merge_update()
    local arr={}
    for _,player in pairs(players) do
        table.insert(arr,player)
    end
    table.sort(arr,function (a,b)
        return a.playerid<b.playerid        
    end)
    
    for _,player in ipairs(arr) do
        local cell_arr={}
        for _,cell in pairs(player.cells) do
            table.insert(cell_arr,cell)
        end
        table.sort(cell_arr,function (a,b)
                return a.id<b.id
            end)
        --所有小球合并计数减一
        for _,cell in ipairs(cell_arr) do
            if(cell.merge_timer>0) then
                cell.merge_timer=cell.merge_timer-1
            end
        end
        --检测是否可合并
        for i=1,#cell_arr do
            for j=i+1,#cell_arr do
                local a,b=cell_arr[i],cell_arr[j]
                if a.merge_timer<=0 and b.merge_timer<=0 then
                    if player.cells[a.id] and player.cells[b.id] then
                        local dx=a.x-b.x
                        local dy=a.y-b.y
                        local dist=math.sqrt(dx^2+dy^2)
                        if dist<a.size+b.size then
                            --小的合到大的
                            local big,small
                            if a.size>b.size then
                                big,small=a,b
                            elseif a.size<b.size then
                                big,small=b,a
                            elseif a.id>b.id then--如果size一样，新的合并到老的
                                big,small=b,a
                            elseif a.id<b.id then
                                big,small=a,b
                            end
                            local total_mass=Cell.cal_mass(a.size)+Cell.cal_mass(b.size)
                            big.size=Cell.mass_to_size(total_mass)
                            player.cells[small.id]=nil

                            --更新网格
                            cell_grid:remove(small.id)
                            cell_grid:update(big)
                        end

                    end
                end
            end
        end

    end
    
end

local function collision_update()
    SceneCollision.collision_all(players,cell_grid)
end
--重建四叉树
local function cleanup()
    --超过阈值则重建
    if  dead_food_in_tree.count>FOOD_MAX*0.3 then
        food_tree:clear()
        for _,food in pairs(foods) do
            food_tree:insert(food)
        end
        dead_food_in_tree.count=0
    end
end
--帧初处理指令
local function process_commands(frame_event)
    local arr={}
    for _,player in pairs(players) do
        table.insert(arr,player)
    end
    table.sort(arr,function (a, b)
        return a.playerid<b.playerid
    end)
    for _,player in ipairs(arr) do
        for _,action in ipairs(player.pending_actions) do
            if action.kind=="split" then
                local new_cells=SceneSplit.do_split(player,action)
                for _,c in ipairs(new_cells or {}) do
                    --各小球只记录自己的新球
                    if not frame_event.new_cells[player.playerid] then
                        frame_event.new_cells[player.playerid]={}
                    end
                    table.insert(frame_event.new_cells[player.playerid],{
                        cell_id=c.id;
                        parent_cell_id=c.parent_id;
                        playerid=c.playerid;
                        action_seq=action.seq or player.last_input_seq;
                        x = c.x;
                        y = c.y;
                        size = c.size;
                        boost_vx = c.boost_vx;
                        boost_vy = c.boost_vy;
                    })
                end
            end
            if action.kind=="spit" then
                local new_spores=SceneSplit.spit_spore(player,spores,action)
                for _,spore in ipairs(new_spores or {}) do
                    --各小球只记录自己的新孢子
                    if not frame_event.new_spores[player.playerid] then
                        frame_event.new_spores[player.playerid]={}
                    end

                    table.insert(frame_event.new_spores[player.playerid],
                    {spore_id=spore.id,
                    x=spore.x,
                    y=spore.y,
                    vx=spore.vx,
                    vy=spore.vy,
                    action_seq= action.seq or player.last_input_seq,
                    owner_playerid=spore.owner_id,
                    source_cell_id = spore.source_cell_id;
                })
                end
            end
        end
        player.pending_actions={}
    end
end
--帧末广播
local function broadcast_frame_update(frame_event)


    for _, player in pairs(players) do
        local cells_msg, spores_msg =build_player_visible_snapshot(player)
        local msg={
            "frame_update",
        cells=cells_msg,
        new_foods=frame_event.new_foods,
        new_spores=frame_event.new_spores[player.playerid] and frame_event.new_spores[player.playerid] or nil,
        eaten_food_ids=frame_event.eaten_food_ids,
        tick=frame,
        dead_playerids=frame_event.dead_playerids,
        new_cells=frame_event.new_cells[player.playerid] and frame_event.new_cells[player.playerid] or nil,
        spores=spores_msg,
        ack=player.last_input_seq
        }
        send_frame_msg(player,msg)
    end
end
local function update(frame)
    if not game_started then
        return
    end
    local frame_event={
        cells={},
        new_foods = {},
        new_spores = {},
        eaten_food_ids = {},
        eaten_spore_ids = {},
        eaten_cell_ids = {},
        dead_playerids = {},
        new_cells={},
    }
    flush_pending_leaves() --删除玩家
    flush_pending_rebirth()--复活玩家
    process_commands(frame_event)
    food_update(frame_event) --食物生成
    spores_move()--移动孢子
    cell_move()
    cleanup()--重建四叉树
    eat_food(frame_event)
    eat_spore()
    eat_cell(frame_event)
    --如果以后后面还用四叉树，记得这里再重建一次
    merge_update()--合并
    collision_update()--防止重叠
    
    broadcast_frame_update(frame_event)--帧末广播
    flush_pending_enters() --加入玩家
end

s.init = function(arg_mode_id,arg_room)
    mode_id=arg_mode_id
    room=arg_room
    assert(room)
    game_started=false
    math.randomseed(skynet.now() + s.id)
    skynet.fork(function()
        local stime = skynet.now()
        while true do
            frame = frame + 1
            local isok, err = pcall(update, frame)
            if not isok then
                skynet.error(err)
            end
            local etime = skynet.now()
            local waittime = frame * 5 - (etime - stime) --减去update运行的时间
            if waittime <= 0 then
                waittime = 2 --如果update耽搁太久，帧数落后于当前理应的帧数，追帧
            end
            skynet.sleep(waittime)
            
        end
    end)
end

function s.resp.shutdown_scene()
    skynet.exit()
end

function s.resp.get_weight(source)
    local ret={}
    for playerid,weight_score in pairs(left_weights)do
        table.insert(ret,{
            playerid=playerid,
            weight_score=weight_score
        })
    end

    for playerid,p in pairs(players) do
        if not left_weights[playerid] then
            table.insert(ret,{
                playerid=playerid,
                weight_score=calc_player_weight_score(p)
            })
        end
    end
    return ret
end

s.start(...)
