local skynet=require "skynet"
local mysql=require "skynet.db.mysql"
local socket=require "skynet.socket"
local db= nil
local function connect(fd,addr)
	socket.start(fd)
	print(fd .. " connected addr " .. addr)
	while true do
		local readdata=socket.read(fd)
		if readdata then
			if readdata=="get\r\n" then--返回留言板内容
				local res=db:query("select * from msgs")
				for i,v in pairs(res) do
					socket.write(fd,v.id .. " " .. v.text .. "\r\n")
				end
			else--留言
				local data=string.match(readdata,"set (.-)\r\n")--匹配set 开头，\r\n结尾的字符，（）意思是只要括号里面的，不要外面的set 和\r\n，.表示任意字符，-代表非贪婪匹配，匹配到第一个\r\n就停
				local res=db:query("insert into msgs (text) values (\'" .. data .. "\')")
				
			end	
		else--断开连接
			print(fd .." closed")
			socket.close(fd)
		end
	end
end

skynet.start(function()
	--网络监听
	local listenfd=socket.listen("0.0.0.0",8888)
	socket.start(listenfd,connect)	
	--连接数据库
	db=mysql.connect({
		host="192.168.164.129",
		port=3306,
		database="message_board",
		user="root",
		password="123456",
		max_packet_size=1024*1024,--最大接收包大小（1MB
		on_connect=nil--连接建立时的回调函数
	})
	if db then
		skynet.error("服务器成功连接数据库\r\n")
	else
		skynet.error("服务器连接数据库失败\r\n")
	end
end

)
