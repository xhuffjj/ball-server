local Cell = require("cell")
local Spore = require("spore")
--分裂和吐孢子的函数

local Split = {}

local MAX_CELLS = 16 --最大子球数
local MIN_SPLIT_SIZE = 4 --最小分裂尺寸
local MIN_SPIT_SIZE = 3 --最小吐孢子尺寸
local MERGE_COOLDOWN = 60 --合并冷却期（单位服务器帧，300帧=15s)
local SPLIT_BOOST = 10 --分裂冲量
local SPLT_INIT_SPEED = 15 --孢子初速度

local function count_cells(player)
    local n = 0
    for _ in pairs(player.cells) do
        n = n + 1
    end
    return n
end
--获取速度的单位向量
local function get_cell_action_dir(cell,action)
    
    if action.moving then
        local dx=action.target_x-cell.x
        local dy=action.target_y-cell.y
        local dist=math.sqrt(dx*dx+dy*dy)
        if dist>0.001 then
            return dx/dist,dy/dist
        end
    end
    --如果move为false,huoz
    --看小球最后方向
    local cell_dir_=action.cell_dirs[cell.id]
    local cell_dir_x
    local cell_dir_y
    if cell_dir_ then--如果快照存在方向
        cell_dir_x=cell_dir_.last_dir_x
        cell_dir_y=cell_dir_.last_dir_y
    else--否则说明是这帧分裂出的新球，没快照，我们用最新方向
        cell_dir_x=cell.last_dir_x
        cell_dir_y=cell.last_dir_y
    end
    return cell_dir_x or 1 , cell_dir_y or 0
end

--分裂函数，返回新增小球
function Split.do_split(player,action)
    local results = {}
    local count = count_cells(player)
    --是否数量上限
    if count >= MAX_CELLS then
        return
    end

    --收集可分裂球到数组（准备排序）
    local splittable = {}
    for _, cell in pairs(player.cells) do
        if cell.size >= MIN_SPLIT_SIZE then
            table.insert(splittable, cell)
        end
    end
    if #splittable == 0 then
        return
    end
    --升序
    table.sort(splittable, function(a, b)
        return a.id < b.id
    end)
    --分裂
    
    for _, cell in ipairs(splittable) do
        --到达上限停止分裂
        if count_cells(player) >= MAX_CELLS then
            break
        end
        --小球质量减半
        local old_mass = Cell.cal_mass(cell.size)
        local new_size = Cell.mass_to_size(old_mass / 2)
        cell.size = new_size
        cell.merge_timer = MERGE_COOLDOWN


        --建新球
        local new_cell = Cell.new(player.playerid, cell.x, cell.y, new_size)

        --获取分裂方向
        local dir_x,dir_y=get_cell_action_dir(cell,action)
        --设置冲量
        new_cell.boost_vx = SPLIT_BOOST * dir_x
        new_cell.boost_vy = SPLIT_BOOST * dir_y
        new_cell.last_dir_x = dir_x
        new_cell.last_dir_y = dir_y
        -- 连续移动统一由 init.lua 的 cell_move 按 player.move_x / move_y 驱动


        new_cell.merge_timer = MERGE_COOLDOWN
        new_cell.parent_id=cell.id
        --添加新球
        player.cells[new_cell.id] = new_cell
        table.insert(results,new_cell)
    end
    return results
end

--返回新增的spore数组.广播用
function Split.spit_spore(player, spores,action)
    local results = {}
    local arr = {}
    for _, cell in pairs(player.cells) do
        table.insert(arr, cell)
    end
    table.sort(arr, function(a, b)
        return a.id < b.id
    end)
    
    for _, cell in ipairs(arr) do
        if cell.size >= MIN_SPIT_SIZE then
            local spore_mass = Cell.cal_mass(1.0) --1.0大小的孢子
            local old_mass = Cell.cal_mass(cell.size)
            if old_mass > spore_mass then --小球要能分出孢子的质量
                cell.size = Cell.mass_to_size(old_mass - spore_mass)
                --获取吐孢子方向
                local dir_x, dir_y = get_cell_action_dir(cell, action)
                local new_spore = Spore.new(
                    player.playerid,
                    cell.id,
                    cell.x+dir_x * cell.size,
                    cell.y+dir_y * cell.size,
                    SPLT_INIT_SPEED * dir_x,
                    SPLT_INIT_SPEED * dir_y
                )
                spores[new_spore.id] = new_spore
                table.insert(results, new_spore)
            end
        end
    end
    if #results == 0 then
        return nil
    end
    return results
end

return Split
