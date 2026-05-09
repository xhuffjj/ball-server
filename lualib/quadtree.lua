--[[
    四叉树模块 - 用于空间碰撞检测优化
    将二维空间递归划分为四个象限，加速范围查询
    坐标系采用屏幕坐标系，左上角为原点，y轴向下
    分界线的点对象归右或者下
    有体积的且压线（相切也算）的对象留在父节点
]]

local Quadtree = {}
Quadtree.__index = Quadtree

-- 创建新的四叉树
-- bounds: {x=左上角x, y=左上角y, width=宽度, height=高度}
-- max_objects: 节点分裂前的最大对象数 (默认10)
-- max_levels: 最大深度 (默认5)
function Quadtree.new(bounds, max_objects, max_levels, level)
    local self = setmetatable({}, Quadtree)
    self.bounds = bounds
    self.max_objects = max_objects or 10
    self.max_levels = max_levels or 5
    self.level = level or 0
    self.objects = {}
    self.nodes = {} -- 四个子节点: 1=NE, 2=NW, 3=SW, 4=SE
    return self
end

-- 清空四叉树
function Quadtree:clear()
    self.objects = {}
    for i = 1, 4 do
        if self.nodes[i] then
            self.nodes[i]:clear()
            self.nodes[i] = nil
        end
    end
end

-- 分裂成四个子区域
function Quadtree:split()
    local x = self.bounds.x
    local y = self.bounds.y
    local subWidth = self.bounds.width / 2
    local subHeight = self.bounds.height / 2
    local nextLevel = self.level + 1

    -- NE (右上)
    self.nodes[1] = Quadtree.new(
        { x = x + subWidth, y = y, width = subWidth, height = subHeight },
        self.max_objects, self.max_levels, nextLevel
    )
    -- NW (左上)
    self.nodes[2] = Quadtree.new(
        { x = x, y = y, width = subWidth, height = subHeight },
        self.max_objects, self.max_levels, nextLevel
    )
    -- SW (左下)
    self.nodes[3] = Quadtree.new(
        { x = x, y = y + subHeight, width = subWidth, height = subHeight },
        self.max_objects, self.max_levels, nextLevel
    )
    -- SE (右下)
    self.nodes[4] = Quadtree.new(
        { x = x + subWidth, y = y + subHeight, width = subWidth, height = subHeight },
        self.max_objects, self.max_levels, nextLevel
    )
end

-- 获取点或者圆所属的象限索引 (1-4)，如果圆跨越边界则返回 0，表示属于多个象限
function Quadtree:getIndex(obj)
    local midX = self.bounds.x + self.bounds.width / 2
    local midY = self.bounds.y + self.bounds.height / 2
    local r = obj.size or 0 -- 半径

    -- 对象在上半部分
    local topQuadrant = (obj.y + r) < midY
    -- 对象在下半部分
    local bottomQuadrant = (obj.y - r) >= midY
    -- 对象在左半部分
    local leftQuadrant = (obj.x + r) < midX
    -- 对象在右半部分
    local rightQuadrant = (obj.x - r) >= midX

    if topQuadrant then
        if rightQuadrant then
            return 1 -- NE
        elseif leftQuadrant then
            return 2 -- NW
        end
    elseif bottomQuadrant then
        if leftQuadrant then
            return 3 -- SW
        elseif rightQuadrant then
            return 4 -- SE
        end
    end

    return 0 --若有尺寸（非点）的物体跨越了多个象限，返回0
end

-- 插入对象到四叉树
-- obj 必须有 x, y 属性
function Quadtree:insert(obj)
    -- 如果已经分裂，尝试插入到子节点
    if self.nodes[1] then
        local index = self:getIndex(obj)
        if index > 0 then
            self.nodes[index]:insert(obj)
            return
        end
    end

    -- 插入到当前节点
    table.insert(self.objects, obj)

    -- 检查是否需要分裂
    if #self.objects > self.max_objects and self.level < self.max_levels then
        if not self.nodes[1] then
            self:split()
        end

        -- 重新分配对象到子节点
        local i = 1
        while i <= #self.objects do
            local index = self:getIndex(self.objects[i])
            if index > 0 then
                local obj = table.remove(self.objects, i)
                self.nodes[index]:insert(obj)
            else
                i = i + 1
            end
        end
    end
end

-- 检查矩形是否与当前结点边界相交，rect:查询矩形，bounds:当前结点边界
local function intersects(rect, bounds)
    return not (rect.x > bounds.x + bounds.width or
        rect.x + rect.width < bounds.x or
        rect.y > bounds.y + bounds.height or
        rect.y + rect.height < bounds.y)
end

-- 查询与给定矩形区域重叠的所有对象，retrieve：查询
-- rect: {x=左上角x, y=左上角y, width=宽度, height=高度}
function Quadtree:retrieve(rect, result)
    result = result or {}

    -- 如果查询区域与当前边界不相交，直接返回
    if not intersects(rect, self.bounds) then
        return result
    end

    -- 添加当前节点的所有对象
    for _, obj in ipairs(self.objects) do
        -- 检查对象是否在查询矩形内
        if obj.x >= rect.x and obj.x <= rect.x + rect.width and
            obj.y >= rect.y and obj.y <= rect.y + rect.height then
            table.insert(result, obj)
        end
    end

    -- 递归查询子节点
    if self.nodes[1] then
        for i = 1, 4 do
            self.nodes[i]:retrieve(rect, result)
        end
    end

    return result
end


-- cx, cy: 圆心坐标
-- radius: 半径，
--retrieveInRadius翻译：在半径内检索
-- 查询以点为中心、指定半径的圆形区域内和边界的所有对象（包含边界上的点和边界相切的圆）
function Quadtree:retrieveInRadius(cx, cy, radius, result)
    result = result or {}

    -- 用包围盒快速过滤
    local rect = {
        x = cx - radius,
        y = cy - radius,
        width = radius * 2,
        height = radius * 2
    }

    -- 如果包围盒与当前边界不相交，直接返回
    if not intersects(rect, self.bounds) then
        return result
    end

    -- 检查当前节点的对象
    local radiusSq = radius * radius
    for _, obj in ipairs(self.objects) do
        local dx = obj.x - cx
        local dy = obj.y - cy
        local objR = obj.size or 0 --对象的半径
        --判断检索圆和对象圆是否相交：圆心距离<半径和
        local threshold = radius + objR
        if dx * dx + dy * dy <= threshold * threshold then
            table.insert(result, obj)
        end
    end

    -- 递归查询子节点
    if self.nodes[1] then
        for i = 1, 4 do
            self.nodes[i]:retrieveInRadius(cx, cy, radius, result)
        end
    end

    return result
end

return Quadtree
