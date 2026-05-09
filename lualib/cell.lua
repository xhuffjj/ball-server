local Cell = {}

local BASE_SPEED = 5.0
local MIN_SPEED = 1.0
local EAT_RATIO = 1.25 --可吃比例

local cell_maxid = 0

function Cell.new(playerid, x, y, size)
    cell_maxid = cell_maxid + 1

    return {
        id = cell_maxid, --分配场景全局唯一id
        playerid = playerid, --属于哪个玩家
        parent_id=-1,--父球id
        x = x,
        y = y,
        size = size,
        merge_timer = 0, --可合并倒计时
        --分裂/弹射的冲量（逐渐衰减为0）
        boost_vx = 0,
        boost_vy = 0,
        protected_timer = 0, --无敌倒计时
        last_dir_x=1,--最后朝向
        last_dir_y=0
    }
end

--根据大小计算速度
function Cell.calc_speed(size)
    --初始小球速度为5，大小大于25后速度固定为1
    return math.max(MIN_SPEED, BASE_SPEED / math.sqrt(size))
end

function Cell.mass_to_size(mass)
    return math.sqrt(mass)
end

--质量=size*2
function Cell.cal_mass(size)
    return size * size
end

--a是否能吃b
function Cell.can_eat(a, b)
    if a.playerid == b.playerid then
        return false
    end --不能吃自己的球

    if b.protected_timer > 0 then
        return false
    end

    if a.size <= b.size * EAT_RATIO then
        return false
    end
    local dx = a.x - b.x
    local dy = a.y - b.y
    return dx * dx + dy * dy < a.size * a.size
end

return Cell
