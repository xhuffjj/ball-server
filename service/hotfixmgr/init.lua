local skynet = require("skynet")
local s = require("service")
local runconfig = require("runconfig")

local ALLOW_AGENT_MODULE = {
    bag = true,
    achieve = true,
    mail = true,
    friend = true,
    match = true,
}

local ALLOW_AGENT_CONFIG = {
    item_config = true,
    achieve_config = true,
}

local function check_name(name, allow)
    if type(name) ~= "string" or name == "" then
        return false, "bad name"
    end
    --[]字符集合
    --^取反，%w字母或数字,%.这是.的转义
    --查找name是否存在不是字母数字下划线和点号等非法字符
    if name:find("[^%w_%.]") then
        return false, "invalid name: " .. name
    end
    if allow and not allow[name] then
        return false, "not allowed: " .. name
    end
    return true
end

function s.resp.hotfix_agent_module(source, modname, reload_config)
    --reload_config为true时，模块会重新加载配置文件（如果有的话）
    local ok, err = check_name(modname, ALLOW_AGENT_MODULE)
    if not ok then
        return false, err
    end

    if reload_config ~= nil and type(reload_config) ~= "boolean" then
        return false, "reload_config must be boolean"
    end

    skynet.error(
        string.format(
            "[hotfixmgr] hotfix agent module=%s reload_config=%s",
            modname,
            tostring(reload_config)
        )
    )

    return s.call(
        runconfig.agentmgr.node,
        "agentmgr",
        "hotfix_agents_module",
        modname,
        reload_config
    )
end

function s.resp.hotfix_agent_config(source, config_name)
    local ok, err = check_name(config_name, ALLOW_AGENT_CONFIG)
    if not ok then
        return false, err
    end
    skynet.error("[hotfixmgr] hotfix agent config=" .. config_name)
    return s.call(runconfig.agentmgr.node, "agentmgr", "hotfix_agents_config", config_name)
end

s.start(...)
