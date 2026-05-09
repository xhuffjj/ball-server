--这是一个生产类的工厂函数

local function class(classname, super)
    assert(type(classname) == "string" and #classname > 0, "class() requires a valid classname string")

    --类的表
    local cls = {}
    --如果有父类
    if super then
        assert(type(super) == "table", "super class must be a table")
        setmetatable(cls, { __index = super }) --用{__index=super}而不用super，这样super里面就可以不用放__index=super了，全放函数（虽然通过这个模板生产的类表里面有__index=自身)
        --父类表保存下来，调用和父类的同名函数时要用，虽然我们应该避免同名，但是ctor这个初始化函数是同名的
        --简化getmetatable(子类表).__index这个找父类表的流程
        cls.super = super
    end
    cls.__index = cls
    cls.__cname = classname --保存一下类名，类外可以根据类表获得类名字符串
    cls.__is_class = true
    --调用方法：实例：is_a（类或类名）   /     类：is_a(类或类名)
    function cls:is_a(target_class_or_name)
        --获取当前self的类表
        local current = rawget(self, "__is_class") and self or getmetatable(self) --有__cname字段说明是类表，否则是实例表
        while current do
            if current == target_class_or_name or current.__cname == target_class_or_name then
                return true
            end
            current = current.super
        end
        return false
    end

    --子类如果没写 ctor/dtor，会自动继承父类 ctor/dtor
    --ctor:初始化函数
    --dtor:垃圾回收前的清理函数

    --对象可以主动调用distory进行清理
    function cls:destroy()
        if rawget(self, "__destroyed") then --已经销毁了，直接返回
            return
        end
        self.__destroyed = true
        if type(self.dtor) == "function" then
            self:dtor()
        end
    end

    --析构函数
    cls.__gc = function(instance)
        instance:destroy()
    end

    --构造函数
    function cls.new(...)
        local instance = {}
        --设置对象表的元表为类表
        setmetatable(instance, cls)
        

        --初始化实例
        local ctor = cls.ctor
        if ctor then
            ctor(instance, ...)
        end

        return instance
    end

    return cls
end

return class
