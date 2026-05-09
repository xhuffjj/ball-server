local skynet = require "skynet"
local s = require "service"

function s.resp.newservice(source, ...)
    local srv = skynet.newservice(...)
    return srv
end

function s.resp.abort(sourse)
    skynet.fork(
        function ()
            skynet.sleep(10)
            skynet.abort()
        end
    )
    return true
    
end

s.start(...)
