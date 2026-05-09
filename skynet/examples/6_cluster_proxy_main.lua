local skynet=require "skynet"
local cluster=require "skynet.cluster"
require "skynet.manager"

skynet.start(function ()
	cluster.reload({
		node1="127.0.0.1:7001",
		node2="127.0.0.1:7002"
	})
	local mynode=skynet.getenv("node")
	if mynode=="node1" then
		cluster.open("node1")
		local ping1=skynet.newservice("ping_cluster")
		local ping2=skynet.newservice("ping_cluster")
		local pong =cluster.proxy("node2","pong")
		
		skynet.name("ping1", ping1)
		skynet.name("ping2", ping1)
		skynet.send(pong,"lua","ping","node1","ping1",10)
		skynet.send(pong,"lua","ping","node1","ping2",10)
	elseif mynode=="node2" then
		cluster.open("node2")
		local ping3=skynet.newservice("ping_cluster")
		skynet.name("pong",ping3)
	end
end

)
