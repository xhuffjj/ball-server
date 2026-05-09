package.cpath = "luaclib/?.so"
package.path = "lualib/?.lua;examples/?.lua"

local socket = require "client.socket"

local fd = socket.connect("127.0.0.1", 8888)
socket.usleep(1 * 1000000)
--大端+16位无符号整数+13字节字符串
local bytes = string.pack(">Hc13Hc4Hc2", 13, "login,101,102", 4, "work", 4, "wo")

socket.send(fd, bytes)

socket.usleep(1 * 100000)

bytes = string.pack(">c2", "oo")
socket.send(fd, bytes)
socket.close(fd)
