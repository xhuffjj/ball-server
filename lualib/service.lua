local skynet = require "skynet"
local cluster = require "skynet.cluster"
require "skynet.manager"

local M = {
	name = "",
	id = 0,
	--回调函数,服务初始化和结束时调用
	exit = nil,
	init = nil,
	--存放服务器内部各服务间的远程函数调用
	resp = {},
	filter_cmd=nil--消息过滤钩子,dispatch中执行消息处理函数前会问过滤器能不能执行
}

local function traceback(err)
	skynet.error(tostring(err))
	skynet.error(debug.traceback())
end

local function dispatch(session, address, cmd, ...)
	local fun = M.resp[cmd]

	if not fun then
		skynet.ret()
		return
	end

	if M.filter_cmd then
		local ok,pass=xpcall(M.filter_cmd, traceback,cmd,session,address,...)
		if not ok or not pass then
			skynet.ret()
			return
		end
		
	end
	--如果不用 xpcall，接收方这条消息处理失败，服务不一定完全崩溃。
	--真正的问题是：没有调用 ret/retpack，导致发送方阻塞等待。
	--所以用xpcall确保无论函数成功还是失败，都会给调用方一个回复，防止调用方永久阻塞。
	local ret = table.pack(xpcall(fun, traceback, address, ...))
	local isok = ret[1]

	if not isok then
		skynet.ret() --返回nil
		--如果xpcall调用失败，返回的nil会与正常调用返回的false在逻辑上等价，
		--所以调用失败时，调用方在判断调用结果时会有一些迷惑人的输出
		return
	end
	--skynet会自动判断session是否是0，如果是0，会直接丢弃这个包，所以可以ret
	skynet.retpack(table.unpack(ret, 2, ret.n)) --标准的 table.unpack(t, i) 如果不指定结束索引，可能会丢失结尾的 nil，我们加上结束索引ret.n
end

local function init(...)
	skynet.dispatch("lua", dispatch)
	if M.init then
		M.init(...)
	end
end


function M.start(name, id, ...)
	M.name = name
	M.id = tonumber(id)
	local args=table.pack(...)
	skynet.start(function ()
		init(table.unpack(args,1,args.n))
	end)
end

function M.call(node, srv, ...)
	local mynode = skynet.getenv("node")
	if mynode == node then
		return skynet.call(srv, "lua", ...)
	else
		return cluster.call(node, srv, ...)
	end
end

function M.send(node, srv, ...)
	local mynode = skynet.getenv("node")
	if mynode == node then
		return skynet.send(srv, "lua", ...)
	else
		return cluster.send(node, srv, ...)
	end
end

return M
