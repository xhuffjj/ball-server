--防止重叠模块
local Collision = {}
--迭代次数
local COLLISION_ITERS = 3
--场景边界
local SCENE_WIDTH = 1000
local SCENE_HIGH = 1000
--八个方向单位向量
local OVERLAP_DIRS = {
    { 1.0, 0.0 },
    { 0.70710678, 0.70710678 },
    { 0.0, 1.0 },
    { -0.70710678, 0.70710678 },
    { -1.0, 0.0 },
    { -0.70710678, -0.70710678 },
    { 0.0, -1.0 },
    { 0.70710678, -0.70710678 },
}
--给一对球取一个兜底方向
local function get_pair_fallback_dir(a, b)
    local id1, id2 = a.id, b.id
    if id1 > id2 then
        id1, id2 = id2, id1
    end
    --id乘大质数混成一个分布更均匀的值，避免很多相邻 id 算出来总扎堆到同一个方向槽里
    local h = (id1 * 73856093 + id2 * 19349663) % #OVERLAP_DIRS
    local dir = OVERLAP_DIRS[h + 1]
    return dir[1], dir[2]
end
--推开一个玩家所有重合的小球
function Collision.self_collision(player,cell_grid)
    --收集小球到数组方便遍历和排序，固定运行结果
    local arr = {}
    for _, v in pairs(player.cells) do
        table.insert(arr, v)
    end

    table.sort(arr, function(a, b)
        return a.id < b.id
    end) --把小球按照id排序,按顺序推，让客户端可预测
    --没必要推
    if #arr <= 1 then
        return
    end

    local touched_cells={}
    for iter = 1, COLLISION_ITERS do --多次迭代
        for i = 1, #arr do
            for j = i + 1, #arr do
                local dx = arr[i].x - arr[j].x
                local dy = arr[i].y - arr[j].y
                --圆心距离平方
                local dist_sq = dx ^ 2 + dy ^ 2
                --圆心距离
                local dist = math.sqrt(dist_sq)
                --两圆半径和，即应该的不重合最小圆心距离
                local min_dist = arr[i].size + arr[j].size
                --重合度计算
                local overlap = min_dist - dist
                if overlap<=0 then--不重叠就跳过
                    goto continue
                end
                local nx, ny
                if dist < 0.001 then --如果圆心几乎重合
                    --随机给一个方向
                    nx, ny = get_pair_fallback_dir(arr[i], arr[j])
                else
                    --方向向量归一化
                    nx = dx / dist
                    ny = dy / dist
                end

                --推开距离
                local push_distance_x = nx * overlap / 2
                local push_distance_y = ny * overlap / 2

                --推开
                arr[i].x = arr[i].x + push_distance_x
                arr[i].y = arr[i].y + push_distance_y
                arr[j].x = arr[j].x - push_distance_x
                arr[j].y = arr[j].y - push_distance_y

                --边界钳制
                arr[i].x = math.max(0, math.min(SCENE_WIDTH, arr[i].x))
                arr[i].y = math.max(0, math.min(SCENE_HIGH, arr[i].y))
                arr[j].x = math.max(0, math.min(SCENE_WIDTH, arr[j].x))
                arr[j].y = math.max(0, math.min(SCENE_HIGH, arr[j].y))

                touched_cells[arr[i].id]=arr[i]
                touched_cells[arr[j].id]=arr[j]
                
                ::continue::
            end
        end
    end
    for _,c in pairs(touched_cells) do
        cell_grid:update(c)
    end
end

--推开所有小球
function Collision.collision_all(players,cell_grid)
    local arr = {}
    for _, player in pairs(players) do
        table.insert(arr, player)
    end
    table.sort(arr, function(a, b)
        return a.playerid < b.playerid
    end)
    for _, player in ipairs(arr) do
        Collision.self_collision(player,cell_grid)
    end
end

return Collision
