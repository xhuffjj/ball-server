local Ceil = require("cell")
--吃孢子，食物，小球的函数
local Eat = {}

--返回吃食物的小球和被吃的食物
function Eat.eat_food(players, foods, food_tree, dead_in_tree,cell_grid)
    --dead_in_tree是里面放着count键，用来树中把被吃的脏食物计数作为引用传入函数
    local arr = {}
    for _, player in pairs(players) do
        for cid, c in pairs(player.cells) do
            table.insert(arr, c)
        end
    end

    table.sort(arr, function(a, b)
        return a.id < b.id
    end)
    -- 使用四叉树查询附近食物
    local events = {}

    for _, c in ipairs(arr) do
        -- 查询子球附近的食物（搜索半径为玩家size+1，放宽限制，因为小球吃东西后会变大，有可能吃到原来吃不到的对象）
        local searchRadius = c.size + 1
        local nearbyFoods = food_tree:retrieveInRadius(c.x, c.y, searchRadius)
        table.sort(nearbyFoods, function(a, b)
            return a.id < b.id
        end)
        for _, f in ipairs(nearbyFoods) do
            -- 碰撞检测：距离的平方 < 玩家的size，food[f.id]会过滤脏食物和前面循环被吃的食物
            if foods[f.id] and (c.x - f.x) ^ 2 + (c.y - f.y) ^ 2 < c.size ^ 2 then
                c.size = Ceil.mass_to_size(Ceil.cal_mass(c.size) + 1)

                --尺寸变了要更新网格
                cell_grid:update(c)
                foods[f.id] = nil
                dead_in_tree.count = dead_in_tree.count + 1 --脏食物加一
                table.insert(events, { cell = c, food = f })
            end
        end
    end

    return events
end

--返回吃方和被吃方，无需脏计数，因为孢子吐出时每帧都在动，必须要重建树
function Eat.eat_spore(players, spores, spore_grid,cell_grid)
    -- 使用四叉树查询附近孢子
    local events = {}

    local arr = {}
    for _, player in pairs(players) do
        for cid, c in pairs(player.cells) do
            table.insert(arr, c)
        end
    end
    table.sort(arr, function(a, b)
        return a.id < b.id
    end)
    for cid, c in ipairs(arr) do
        -- 查询玩家附近的孢子（搜索半径为玩家size+1,）
        local nearbySpores = spore_grid:queryCircle(c.x, c.y, c.size)
        table.sort(nearbySpores, function(a, b)
            return a.id < b.id
        end)
        for _, sp in ipairs(nearbySpores) do
            -- 碰撞检测：距离的平方 <半径之和平方，只要相交就判定成功，spores[sp.id]会过滤脏孢子和前面循环被吃的孢子
            if spores[sp.id] and (c.x - sp.x) ^ 2 + (c.y - sp.y) ^ 2 < (c.size + sp.size) ^ 2 then
                c.size = Ceil.mass_to_size(Ceil.cal_mass(c.size) + Ceil.cal_mass(sp.size))
                spores[sp.id] = nil
                spore_grid:remove(sp.id)
                cell_grid:update(c)
                table.insert(events, { cell = c, spore = sp })
            end
        end
    end

    return events
end

--返回吃方和被吃方,和被吃玩家的id，无需脏计数，因为小球每帧都在动，必须要重建树
function Eat.eat_player(players, cell_grid)
    -- 使用四叉树查询附近小球

    local events = {}
    local arr = {}
    for _, player in pairs(players) do
        for cid, c in pairs(player.cells) do
            if c.protected_timer>0 then
                c.protected_timer=c.protected_timer-1
            end
            table.insert(arr, c)
        end
    end
    table.sort(arr, function(a, b)
        return a.id < b.id
    end)

    local candidates = {} --候选者

    for cid, c in ipairs(arr) do
        --查询玩家小球附近的小球（搜索半径为玩家size*2）
        local nearby = cell_grid:queryCircle(c.x, c.y,c.size+c.size)
        table.sort(nearby, function(a, b)
            return a.id < b.id
        end)
        for _, target_c in ipairs(nearby) do
            if c.id ~= target_c.id and c.playerid ~= target_c.playerid then
                --记录可能发生接触的事件
                table.insert(candidates, {
                    eater_pid = c.playerid,
                    eater_cid = c.id,
                    target_pid = target_c.playerid,
                    target_cid = target_c.id,
                })
            end
        end
    end

    for _, ev in ipairs(candidates) do
        local eater_player = players[ev.eater_pid]
        local eater = eater_player and eater_player.cells[ev.eater_cid]
        local target_player = players[ev.target_pid]
        local target = target_player and target_player.cells[ev.target_cid]

        if eater and target and Ceil.can_eat(eater, target) then
            --合并质量
            eater.size = Ceil.mass_to_size(Ceil.cal_mass(eater.size) + Ceil.cal_mass(target.size))
            cell_grid:update(eater)
            --删除被吃的球
            target_player.cells[target.id] = nil
            cell_grid:remove(target.id)
            table.insert(
                events,
                { eater = eater, dead = target, dead_cell_playerid = target.playerid }
            )
        end
    end

    return events
end

return Eat
