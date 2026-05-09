local skynet = require "skynet"
local cluster=require "skynet.cluster"
local mynode = skynet.getenv("node")






local CMD = {}

function CMD.start(source, target_node,target)--这里的sourse是启动ping服务的服务
    cluster.send(target_node,target, "ping", mynode, skynet.self(),1)
end

function CMD.ping(source, source_node,source_srv,count)
--这里的sourse应该是clusterd服务，因为clusterd服务负责接受别的节点的消息，然后转发给本节点的服务，所以应该用source_node,source_srv传递消息的初始来源
    local id = skynet.self()
    skynet.error("["..id.."] recv ping count="..count)
    skynet.sleep(100)
    cluster.send(source_node,source_srv, "ping",mynode,skynet.self(), count+1)
end
skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
      local f=assert(CMD[cmd])
      f(source,...)
    end)
end)
