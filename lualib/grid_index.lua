local GridIndex={}
GridIndex.__index = GridIndex
--工具函数---------------------------------

-- 把值限制在范围内
local function clamp(v, min_v, max_v)
    return math.max(min_v,math.min(max_v,v))
end


--判断对象圆是否和查询矩形相交（包含相切）
local function circle_intersects_rect(cx,cy,r,min_x,min_y ,max_x, max_y)
    --查找矩形中距离圆心最近的点的坐标
    local closest_x = clamp(cx, min_x, max_x)
    local closest_y = clamp(cy, min_y, max_y)
    --这个点距离圆心的距离
    local dx=closest_x-cx
    local dy=closest_y-cy
    return dx^2+dy^2<=r^2
end
--创建整个场景的网格对象
function GridIndex.new(bounds,cell_size)
    assert(bounds, "GridIndex.new: bounds is required")
    assert(cell_size and cell_size > 0, "GridIndex.new: cell_size must be > 0")
    local self = setmetatable({}, GridIndex)
    self.bounds={--边界数据保存下来
        x = bounds.x,
        y = bounds.y,
        width = bounds.width,
        height = bounds.height,
    }
    self.cell_size = cell_size--网格尺寸
    --场景的左上和右下坐标
    self.min_x = bounds.x
    self.min_y = bounds.y
    self.max_x = bounds.x + bounds.width
    self.max_y = bounds.y + bounds.height
    --列数
    --最少也要1列，小数取上限
    self.cols=math.max(1,math.ceil(bounds.width/cell_size))
    --行数
    self.rows=math.max(1,math.ceil(bounds.height/cell_size))
    --网格桶 [x*self.cols+y+1]->{[对象id]->对象，...}用哈希表进行o1的增删
    self.buckets={}
    --反向索引表 存储对象覆盖网格的范围 [对象id]->{对象，左上角的坐标，右下角的坐标}
    self.records={}
    return self
end

function GridIndex:clear()
    -- 只有测试或整场重置时才需要 clear；正常战斗流程不走全量重建。
    self.buckets = {}
    self.records = {}
end

-- 把二维格子坐标压平成一维桶 key，方便 buckets 用普通表存储。
function GridIndex:_bucket_key(gx, gy)
    return gy * self.cols + gx + 1
end

--兼容性函数，兼容没有id字段的对象
function GridIndex:_object_key(obj)
    -- 优先用稳定 id 做对象键
    return obj.id or obj
end
--读取对应格子的桶，create为true时不存在时会创建
function GridIndex:_get_bucket(gx,gy,create)
    local key=self:_bucket_key(gx,gy)
    local bucket=self.buckets[key]
    if not bucket and create then
        bucket={}
        self.buckets[key]=bucket
    end
    return bucket,key
end
--计算轴对齐包围盒覆盖的网格范围索引
function GridIndex:_cell_range_for_aabb(min_x, min_y, max_x, max_y)
    --Axis-Aligned Bounding Box即aabb，

    --如果包围盒和场景无重叠，返回nil
    if max_x < self.min_x or max_y < self.min_y or min_x > self.max_x or min_y > self.max_y then
        return nil
    end
    --如果max_x或者max_y在场景边界，除出来如果是整数的话，要-1，把位于右下边界的对象归到最后的边界格子管
    --其次，小球可能超出边界，需要钳制索引到合法区间
    local gx0=clamp(math.floor((min_x-self.min_x)/self.cell_size),0,self.cols-1)
    local gy0=clamp(math.floor((min_y-self.min_y)/self.cell_size),0,self.rows-1)
    local gx1 = clamp(math.floor((max_x - self.min_x) / self.cell_size),0,self.cols - 1)
    local gy1 = clamp(math.floor((max_y - self.min_y) / self.cell_size),0,self.rows - 1)

    return gx0, gy0, gx1, gy1
end

--返回对象覆盖的网格范围索引
function GridIndex:_range_for_obj(obj)
    local r=obj.size or 0
    return self:_cell_range_for_aabb(
        obj.x-r,
        obj.y-r,
        obj.x+r,
        obj.y+r
    )
end

--范围插入,把对象放入它覆盖的格子
function GridIndex:_insert_range(obj_key,obj,gx0, gy0, gx1, gy1)
    for gy=gy0,gy1 do
        for gx=gx0,gx1 do
            local bucket=self:_get_bucket(gx,gy,true)
            bucket[obj_key]=obj
        end
    end
end

--范围删除,把对象从它覆盖的格子的桶删除
function GridIndex:_remove_range(obj_key,gx0, gy0, gx1, gy1)
    for gy=gy0,gy1 do
        for gx=gx0,gx1 do
            local bucket,bucket_key=self:_get_bucket(gx,gy,false)
            if bucket then
                bucket[obj_key]=nil
                --如果格子空了，删除格子的表
                if next(bucket)==nil then
                    self.buckets[bucket_key]=nil
                end
            end
        end
    end
end
--删除和旧位置不重叠的范围的格子的对象
function GridIndex:_remove_non_overlap(obj_key, old_gx0, old_gy0, old_gx1, old_gy1, ov_gx0, ov_gy0, ov_gx1, ov_gy1)
    for gy=old_gy0,old_gy1 do
        for gx=old_gx0,old_gx1 do
            --这个格子是否在重叠区域
            local in_overlap=gx>=ov_gx0 and gy>=ov_gy0 and gx<=ov_gx1 and gy<=ov_gy1
            if not in_overlap then
                local bucket,bucket_key=self:_get_bucket(gx,gy,false)
                if bucket then
                    bucket[obj_key]=nil
                    --如果格子空了，删除格子的桶
                    if next(bucket)==nil then
                        self.buckets[bucket_key]=nil
                    end
                end
            end
        end
        
    end
end

--往和新位置不重叠的范围的格子插入对象
function GridIndex:_insert_non_overlap(obj_key, obj, new_gx0, new_gy0, new_gx1, new_gy1, ov_gx0, ov_gy0, ov_gx1, ov_gy1)
    for gy=new_gy0,new_gy1 do
        for gx=new_gx0,new_gx1 do
             --这个格子是否在重叠区域
             local in_overlap=gx>=ov_gx0 and gy>=ov_gy0 and gx<=ov_gx1 and gy<=ov_gy1
            if not in_overlap then
                local bucket=self:_get_bucket(gx,gy,true)
                bucket[obj_key]=obj
            end
        end
    end
end

--对象加入网格，以包围盒的大小
function GridIndex:add(obj)
    local obj_key = self:_object_key(obj)
    --计算对象包围盒范围,格子的返回索引
    local gx0,gy0, gx1, gy1 =self:_range_for_obj(obj)

    --返回的是nil说明对象越界
    if not gx0 then
        return false
    end

    --防御性编程，如果对象已存在,我们转到更新
    local rec=self.records[obj_key]
    if rec then
        rec.obj=obj
        return self:update(obj)
    end

    --新对象第一次入场，我们按照当前覆盖格范围入桶
    self:_insert_range(obj_key,obj,gx0,gy0, gx1, gy1)
    self.records[obj_key]={
        obj=obj,
        gx0= gx0,
        gy0 = gy0,
        gx1 = gx1,
        gy1 = gy1,
    }
    return true
end
--对外api,对象从网格删去
function GridIndex:remove(obj_or_key)
    local obj_key
    if type(obj_or_key)=="table" then
        obj_key=self:_object_key(obj_or_key)
    else
        obj_key=obj_or_key
    end
    --对象的范围记录
    local rec = self.records[obj_key]
    if not rec then
        return false
    end
    --从桶删除
    self:_remove_range(obj_key,rec.gx0,rec.gy0,rec.gx1, rec.gy1)
    --从记录表删除
    self.records[obj_key]=nil
    return true

end

--更新对象在网格中的范围,没有改动的话返回false
function GridIndex:update(obj)
    local obj_key=self:_object_key(obj)
    --旧范围记录
    local rec=self.records[obj_key]
    --新的范围
    local gx0,gy0,gx1,gy1 =self:_range_for_obj(obj)

    --如果越界
    if not gx0 then
        if rec then
            --如果原来在网格中，把它从网格删了
            self:remove(obj_key)
            return true
        end
        return false
    end

    --网格中不存在的话直接加入网格
    if not rec then
        return self:add(obj)
    end

    --防御性编程：对象更到最新
    rec.obj=obj

    --覆盖格范围没变，什么都不做
    if rec.gx0 == gx0 and rec.gy0 == gy0 and rec.gx1 == gx1 and rec.gy1 == gy1 then
        return false
    end
    --计算重叠区的范围
    local ov_gx0=math.max(rec.gx0,gx0)
    local ov_gx1=math.min(rec.gx1,gx1)
    local ov_gy0=math.max(rec.gy0,gy0)
    local ov_gy1=math.min(rec.gy1,gy1)
    --如果重叠区存在的话，ov_gx0<=ov_gx1 ,ov_gy0<=ov_gy1
    local has_overlap=ov_gx0<=ov_gx1 and ov_gy0<=ov_gy1
    if  has_overlap then
        --从离开的范围删了
        self:_remove_non_overlap(obj_key,rec.gx0, rec.gy0, rec.gx1, rec.gy1, ov_gx0, ov_gy0, ov_gx1, ov_gy1)
        --加入新到的范围
        self:_insert_non_overlap(obj_key,obj,gx0,gy0,gx1,gy1,ov_gx0, ov_gy0, ov_gx1, ov_gy1)
    else
        --没重叠的话，直接整个删了再插入
        self:_remove_range(obj_key,rec.gx0, rec.gy0, rec.gx1, rec.gy1)
        self:_insert_range(obj_key,obj,gx0,gy0,gx1,gy1)
    end

    --更新范围的记录表
    rec.gx0=gx0
    rec.gx1=gx1
    rec.gy0 = gy0
    rec.gy1 = gy1
    return true
end

--对外api,合并update和add，外部无需关系对象是否在网格中
function GridIndex:upsert(obj)
    local obj_key = self:_object_key(obj)
    if self.records[obj_key] then
        return self:update(obj)
    end
    return self:add(obj)
end

--对外api，返回查询圆范围内的对象数组(包含和边界相切或者在边界上)
function GridIndex:queryCircle(cx,cy,radius,result,seen)

    --允许复用外部的result和seen减少临时表分配
    result = result or {}
    seen = seen or {}--防止重复插入

    --查询圆转包围盒，算查询要扫哪些格子
    local gx0,gy0,gx1,gy1 =self:_cell_range_for_aabb(
        cx-radius,
        cy-radius,
        cx+radius,
        cy+radius
    )
    --不在网格范围中，返回空数组
    if not gx0 then
        return result
    end
    for gy=gy0,gy1 do
        for gx=gx0,gx1 do
            local bucket=self:_get_bucket(gx,gy,false)
            if bucket then
                for obj_key,obj in pairs(bucket) do
                    if not seen[obj_key] then
                        local obj_r=obj.size or 0
                        local dx=obj.x-cx
                        local dy=obj.y-cy
                        local limit=obj_r+radius
                        if dx^2+dy^2<=limit^2 then
                            table.insert(result,obj)
                            seen[obj_key]=true
                        end
                        
                    end
                end
            end
        end
    end
    return result
end
--对外api，返回查询矩形范围内的对象数组(包含和边界相切或者在边界上)
function GridIndex:queryRect(min_x, min_y, max_x, max_y,result,seen )
    result = result or {}
    seen = seen or {}

    local gx0,gy0,gx1,gy1 =self:_cell_range_for_aabb(
        min_x, min_y, max_x, max_y
    )

    if not gx0 then
        return result
    end

    for gy=gy0,gy1 do
        for gx=gx0,gx1 do
            local bucket=self:_get_bucket(gx,gy,false)
            if bucket then
                for obj_key,obj in pairs(bucket) do
                    if not seen[obj_key] then
                        local obj_r=obj.size or 0
                        local hit
                        if obj_r>0 then
                            --有体积对象按照矩形和圆是否相交计算
                            hit=circle_intersects_rect(obj.x,obj.y,obj_r,min_x,min_y,max_x, max_y)
                        else
                            hit=obj.x>=min_x and obj.x<=max_x and obj.y>=min_y and obj.y<=max_y
                        end
                        if hit then
                            table.insert(result,obj)
                            seen[obj_key]=true
                        end
                    end
                end
            end
        end
    end
    return result
end

return GridIndex