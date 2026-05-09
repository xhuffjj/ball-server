local skynet = require "skynet"
skynet.start(function()
    skynet.newservice("debug_console",8000)
    local ping1 = skynet.newservice("ping")
    local ping2 = skynet.newservice("ping")
    local ping3 = skynet.newservice("ping")
    
    skynet.send(ping1, "lua", "start", ping3)
    skynet.send(ping2,"lua","start",ping3)
    
    skynet.exit()
end)
