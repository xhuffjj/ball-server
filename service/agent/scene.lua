--处理战斗逻辑的模块，负责和scene服务交互
local skynet = require "skynet"
local s = require "service"
local mynode = skynet.getenv("node")
local runconfig = require "runconfig"
s.snode = nil --场景服务所在节点
s.sname = nil --场景服务名


local function random_scene()
    local nodes = {}
    for i, v in pairs(runconfig.scene) do
        table.insert(nodes, i)
        if runconfig.scene[mynode] then
            table.insert(nodes, mynode)
        end
    end
    local idx = math.random(1, #nodes)
    local scenenode = nodes[idx]

    local scenelist = runconfig.scene[scenenode]
    local idx = math.random(1, #scenelist)
    local sceneid = scenelist[idx]
    return scenenode, sceneid
end

function s.client.enter(msg)
    if s.sname then
        return { "enter", code=1, msg="已在场景" }
    end
    local snode, sid = random_scene()
    local sname = "scene" .. sid
    
    local isok,battle_info = s.call(snode, sname, "enter", s.id, mynode, skynet.self())
    if not isok then
        return { "enter", code=1, msg="进入失败" }
    end
    s.sname = sname
    s.snode = snode
    return {
        "enter", code=0,msg="等待战斗链路就绪",
        battle_host=battle_info.host,
        battle_port=battle_info.port,
        battle_conv=battle_info.conv,
        battle_token=battle_info.token,
    }
end

--调用场景服务的leave
function s.leave_scene()
    if not s.sname then--snode和sname是场景服务的节点和名称
        return
    end
    s.call(s.snode, s.sname, "leave", s.id)
    s.snode = nil
    s.sname = nil
end
--客户端请求离开
function s.client.leave(msg)
    if not s.sname then
        return { "leave", code = 1, msg = "不在场景中" }
    end
    s.leave_scene()
    return { "leave", code = 0, msg = "leave_ok" }
end
--战斗网关把玩家踢出场景
function s.resp.battle_leave_scene()
    s.leave_scene()
end

--[[function s.client.input_frame(msg)
    if not s.sname then
        return
    end
    local x = msg.target_x or 0
    local y = msg.target_y or 0
    local moving=msg.moving;
    local input_seq = msg.input_seq or 0
    local split=msg.split
    local spit=msg.spit
    s.call(s.snode, s.sname, "input_frame", s.id, x, y, moving,split,spit,input_seq)
end]]
