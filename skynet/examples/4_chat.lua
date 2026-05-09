local skynet = require "skynet"
local socket = require "skynet.socket"
local clients={}
    
    
   
skynet.start(function()
    local listenfd = socket.listen("0.0.0.0", 8888)
    socket.start(listenfd ,connect)
end)

function connect(fd,addr)
	print(fd .. "connected addr: " .. addr)
	socket.start(fd)
	clients[fd]={}
	while true do--永真循环处理半包粘包，并且维护长连接
		local readdata=socket.read(fd) --没有数据时，协程在此出让cpu
		if readdata then
			print(fd .. "recv:" .. readdata)
			for client,_ in pairs(clients) do
				socket.write(client,readdata)
			end
			
		else
			print(fd .. "closed")
			socket.close(fd)
			clients[fd]=nil
			return
		end
	end
end
