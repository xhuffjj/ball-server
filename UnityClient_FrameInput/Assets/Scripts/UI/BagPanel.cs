using System.Collections.Generic;
using Google.Protobuf;
using UnityEngine;
using Game;

/// <summary>
/// 背包面板 - 物品列表、使用物品
/// </summary>
public class BagPanel : MonoBehaviour
{
    public static BagPanel Instance { get; private set; }

    private List<ItemInfo> _items = new List<ItemInfo>();
    private string _statusMsg = "";
    private float _statusTimer = 0f;
    private Vector2 _scrollPos;

    // 使用数量输入
    private Dictionary<int, string> _useCountInputs = new Dictionary<int, string>();

    // 样式
    private GUIStyle _labelStyle;
    private GUIStyle _smallBtnStyle;
    private GUIStyle _inputStyle;
    private GUIStyle _statusStyle;
    private GUIStyle _headerStyle;
    private bool _stylesInited = false;

    void Awake()
    {
        if (Instance != null && Instance != this) { Destroy(gameObject); return; }
        Instance = this;
    }

    void Start()
    {
        var proto = ProtocolHandler.Instance;
        if (proto == null)
        {
            Debug.LogError("[BagPanel] ProtocolHandler 未初始化，背包模块回调注册失败");
            return;
        }
        proto.On<BagListRes>("baglist", OnBagList);
        proto.On<UseItemRes>("use_item", OnUseItem);

        if (NetworkManager.Instance != null)
        {
            NetworkManager.Instance.OnConnectionChanged += OnConnectionChanged;
        }
    }

    void OnDestroy()
    {
        if (NetworkManager.Instance != null)
        {
            NetworkManager.Instance.OnConnectionChanged -= OnConnectionChanged;
        }
    }

    void Update()
    {
        if (_statusTimer > 0)
        {
            _statusTimer -= Time.deltaTime;
            if (_statusTimer <= 0) _statusMsg = "";
        }
    }

    private void InitStyles()
    {
        UIArtTheme.EnsureInit();

        _labelStyle = new GUIStyle(GUI.skin.label) { fontSize = 14 };
        _labelStyle.normal.textColor = new Color(0.84f, 0.93f, 1f);

        _smallBtnStyle = new GUIStyle(GUI.skin.button) { fontSize = 13, fixedHeight = 28 };
        UIArtTheme.SkinButton(_smallBtnStyle);

        _inputStyle = new GUIStyle(GUI.skin.textField) { fontSize = 13, fixedHeight = 24 };
        UIArtTheme.SkinInput(_inputStyle);

        _statusStyle = new GUIStyle(GUI.skin.label) { fontSize = 13, alignment = TextAnchor.MiddleCenter };
        _statusStyle.normal.textColor = new Color(1f, 0.93f, 0.62f);
        _headerStyle = new GUIStyle(GUI.skin.label) { fontSize = 15, fontStyle = FontStyle.Bold };
        _headerStyle.normal.textColor = new Color(0.72f, 0.93f, 1f);
        _stylesInited = true;
    }

    public void RequestData()
    {
        TrySend("baglist", new BagListReq());
    }

    public void DrawPanel(Rect area)
    {
        if (!_stylesInited) InitStyles();
        UIArtTheme.DrawInset(area);

        float px = area.x + 10;
        float py = area.y + 8;
        float pw = area.width - 20;

        // 标题 + 刷新
        GUI.Label(new Rect(px, py, 200, 22), $"背包 ({_items.Count} 种物品)", _headerStyle);
        if (GUI.Button(new Rect(px + pw - 60, py, 60, 24), "刷新", _smallBtnStyle))
        {
            RequestData();
        }
        py += 28;

        // 状态
        if (!string.IsNullOrEmpty(_statusMsg))
        {
            GUI.Label(new Rect(px, py, pw, 20), _statusMsg, _statusStyle);
            py += 22;
        }

        float contentH = area.y + area.height - py - 5;

        Rect viewRect = new Rect(0, 0, pw - 20, _items.Count * 58 + 10);
        _scrollPos = GUI.BeginScrollView(new Rect(px, py, pw, contentH), _scrollPos, viewRect);

        float cy = 5;
        foreach (var item in _items)
        {
            DrawItem(item, pw - 20, ref cy);
        }

        GUI.EndScrollView();
    }

    private void DrawItem(ItemInfo item, float w, ref float cy)
    {
        UIArtTheme.DrawRow(new Rect(2, cy, w - 24, 42), item.Count > 0);
        GUIStyle richLabel = new GUIStyle(_labelStyle) { richText = true };
        string itemName = ClientStaticData.GetItemName(item.ItemId);
        string itemDesc = ClientStaticData.GetItemDescription(item.ItemId);

        string countColor = item.Count > 0 ? "white" : "#666666";
        GUI.Label(new Rect(5, cy, 200, 28),
            $"<color={countColor}>{itemName}    数量: {item.Count}</color>", richLabel);
        GUI.Label(new Rect(5, cy + 18, 240, 20),
            $"<color=#8FB0C8>{itemDesc}</color>", richLabel);

        if (item.Count > 0)
        {
            // 使用数量输入
            if (!_useCountInputs.ContainsKey(item.ItemId))
                _useCountInputs[item.ItemId] = "1";

            _useCountInputs[item.ItemId] = GUI.TextField(
                new Rect(w - 170, cy + 8, 50, 24),
                _useCountInputs[item.ItemId], _inputStyle);

            if (GUI.Button(new Rect(w - 110, cy + 6, 80, 28), "使用", _smallBtnStyle))
            {
                if (int.TryParse(_useCountInputs[item.ItemId], out int count) && count > 0)
                {
                    TrySend("use_item", new UseItemReq { ItemId = item.ItemId, Count = count });
                }
                else
                {
                    SetStatus("请输入有效的使用数量");
                }
            }
        }

        cy += 47;
        UIArtTheme.DrawSeparator(new Rect(5, cy, w - 10, 1));
        cy += 10;
    }

    // --- 回调 ---
    private void OnBagList(BagListRes res)
    {
        var ids = new HashSet<int>();
        _items.Clear();
        foreach (var item in res.Items)
        {
            _items.Add(item);
            ids.Add(item.ItemId);
        }

        var removedKeys = new List<int>();
        foreach (var kv in _useCountInputs)
        {
            if (!ids.Contains(kv.Key))
            {
                removedKeys.Add(kv.Key);
            }
        }
        foreach (var key in removedKeys)
        {
            _useCountInputs.Remove(key);
        }

        // 有物品的排前面
        _items.Sort((a, b) =>
        {
            if (a.Count > 0 && b.Count <= 0) return -1;
            if (a.Count <= 0 && b.Count > 0) return 1;
            return a.ItemId.CompareTo(b.ItemId);
        });
    }

    private void OnUseItem(UseItemRes res)
    {
        SetStatus(res.Msg);
        if (res.Code == 0)
        {
            RequestData();
            ClientSession.Instance?.RequestBaseInfo();
        }
    }

    private void SetStatus(string msg)
    {
        _statusMsg = msg;
        _statusTimer = 3f;
    }

    private bool TrySend(string cmd, IMessage msg)
    {
        var net = NetworkManager.Instance;
        if (net == null || !net.IsConnected)
        {
            SetStatus("网络未连接");
            return false;
        }
        net.Send(cmd, msg);
        return true;
    }

    private void OnConnectionChanged(bool connected)
    {
        if (connected) return;
        if (ClientSession.Instance != null && ClientSession.Instance.ShouldPreserveStateOnDisconnect())
            return;

        _items.Clear();
        _useCountInputs.Clear();
        _scrollPos = Vector2.zero;
    }
}
