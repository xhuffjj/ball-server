--成就配置

return {
    achieve_list = {
        [1] = { name = "第一桶金", event = "earn_coin", target = 1, reward_coin = 10 },
        [2] = { name = "第十桶金", event = "earn_coin", target = 10, reward_coin = 50 },
        [3] = { name = "金币大亨", event = "earn_coin", target = 100, reward_coin = 200 },
    },
    event_list = {
        earn_coin = { 1, 2, 3 }
    }

}
