local spore = {}

local spore_maxid = 0
local SPORE_SIZE = 1.0
local SPORE_FRICTION = 0.9 --摩擦系数（减速系数）

function spore.new(owner_id,source_cell_id, x, y, vx, vy)
    spore_maxid = spore_maxid + 1
    return {
        owner_id = owner_id,
        source_cell_id=source_cell_id,
        x = x,
        y = y,
        vx = vx,
        vy = vy,
        id = spore_maxid,
        size = SPORE_SIZE,
    }
end

--更新孢子位置（速度衰减）,返回true表示还在运动,false说明停止了
function spore.update(s, scene_w, scene_h)
    --计算新位置
    s.x = s.x + s.vx * 0.2
    s.y = s.y + s.vy * 0.2

    --越界检查
    -- 边界限制
    if s.x < 0 then
        s.x = 0
    end
    if s.x > scene_w then
        s.x = scene_w
    end
    if s.y < 0 then
        s.y = 0
    end
    if s.y > scene_h then
        s.y = scene_h
    end

    --速度衰减
    s.vx = s.vx * SPORE_FRICTION
    s.vy = s.vy * SPORE_FRICTION

    if math.abs(s.vx) < 0.01 and math.abs(s.vy) < 0.01 then
        s.vx = 0
        s.vy = 0
        return false
    end
    return true
end

return spore
