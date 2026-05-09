using System.Collections.Generic;

/// <summary>
/// 客户端静态展示数据。
/// 这里先补齐当前服务端配置里已有的成就和物品名字，避免大厅只显示 ID。
/// </summary>
public static class ClientStaticData
{
    private static readonly Dictionary<int, string> AchieveNames = new Dictionary<int, string>
    {
        { 1, "第一桶金" },
        { 2, "第十桶金" },
        { 3, "金币大亨" },
    };

    private static readonly Dictionary<int, string> AchieveDescriptions = new Dictionary<int, string>
    {
        { 1, "累计获得 1 金币，奖励 10 金币" },
        { 2, "累计获得 10 金币，奖励 50 金币" },
        { 3, "累计获得 100 金币，奖励 200 金币" },
    };

    private static readonly Dictionary<int, string> ItemNames = new Dictionary<int, string>
    {
        { 1001, "小型经验宝石" },
        { 1002, "大型经验宝石" },
        { 2001, "金币袋" },
        { 3001, "红宝石" },
    };

    private static readonly Dictionary<int, string> ItemDescriptions = new Dictionary<int, string>
    {
        { 1001, "获得 10 经验" },
        { 1002, "获得 50 经验" },
        { 2001, "获得 100 金币" },
        { 3001, "闪闪发光的宝石" },
    };

    public static string GetAchieveName(int achieveId)
    {
        if (AchieveNames.TryGetValue(achieveId, out string name))
            return name;
        return $"成就 #{achieveId}";
    }

    public static string GetAchieveDescription(int achieveId)
    {
        if (AchieveDescriptions.TryGetValue(achieveId, out string desc))
            return desc;
        return "暂无描述";
    }

    public static string GetItemName(int itemId)
    {
        if (ItemNames.TryGetValue(itemId, out string name))
            return name;
        return $"物品 #{itemId}";
    }

    public static string GetItemDescription(int itemId)
    {
        if (ItemDescriptions.TryGetValue(itemId, out string desc))
            return desc;
        return "暂无描述";
    }
}
