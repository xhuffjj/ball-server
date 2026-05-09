using System.Collections.Generic;
using Google.Protobuf;
using UnityEngine;
using Game;

/// <summary>
/// 邮件面板 - 邮件列表、读取邮件、领取附件、删除邮件
/// </summary>
public class MailPanel : MonoBehaviour
{
    public static MailPanel Instance { get; private set; }

    private List<MailBrief> _mails = new List<MailBrief>();
    private MailDetail _currentDetail;
    private bool _showDetail = false;
    private string _statusMsg = "";
    private float _statusTimer = 0f;

    private Vector2 _listScroll;
    private Vector2 _detailScroll;

    // 样式
    private GUIStyle _labelStyle;
    private GUIStyle _smallBtnStyle;
    private GUIStyle _statusStyle;
    private GUIStyle _headerStyle;
    private GUIStyle _contentStyle;
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
            Debug.LogError("[MailPanel] ProtocolHandler 未初始化，邮件模块回调注册失败");
            return;
        }
        proto.On<MailListRes>("mail_list", OnMailList);
        proto.On<MailReadRes>("mail_read", OnMailRead);
        proto.On<MailClaimRes>("mail_claim", OnMailClaim);
        proto.On<MailDeleteRes>("mail_delete", OnMailDelete);
        proto.On<MailNotify>("mail_notify", OnMailNotify);

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

        _statusStyle = new GUIStyle(GUI.skin.label) { fontSize = 13, alignment = TextAnchor.MiddleCenter };
        _statusStyle.normal.textColor = new Color(1f, 0.93f, 0.62f);
        _headerStyle = new GUIStyle(GUI.skin.label) { fontSize = 15, fontStyle = FontStyle.Bold };
        _headerStyle.normal.textColor = new Color(0.72f, 0.93f, 1f);
        _contentStyle = new GUIStyle(GUI.skin.label) { fontSize = 13, wordWrap = true };
        _contentStyle.normal.textColor = new Color(0.86f, 0.94f, 1f);
        _stylesInited = true;
    }

    public void RequestData()
    {
        TrySend("mail_list", new MailListReq());
    }

    public void DrawPanel(Rect area)
    {
        if (!_stylesInited) InitStyles();
        UIArtTheme.DrawInset(area);

        float px = area.x + 10;
        float py = area.y + 8;
        float pw = area.width - 20;

        // 状态
        if (!string.IsNullOrEmpty(_statusMsg))
        {
            GUI.Label(new Rect(px, py, pw, 20), _statusMsg, _statusStyle);
            py += 22;
        }

        float contentH = area.y + area.height - py - 5;

        if (_showDetail && _currentDetail != null)
        {
            DrawMailDetail(px, py, pw, contentH);
        }
        else
        {
            DrawMailList(px, py, pw, contentH);
        }
    }

    private void DrawMailList(float x, float y, float w, float h)
    {
        // 刷新按钮
        GUI.Label(new Rect(x, y, 200, 22), $"邮件 ({_mails.Count})", _headerStyle);
        if (GUI.Button(new Rect(x + w - 60, y, 60, 24), "刷新", _smallBtnStyle))
        {
            RequestData();
        }
        y += 28;
        h -= 28;

        Rect viewRect = new Rect(0, 0, w - 20, _mails.Count * 40 + 10);
        _listScroll = GUI.BeginScrollView(new Rect(x, y, w, h), _listScroll, viewRect);
        float cy = 5;
        foreach (var m in _mails)
        {
            UIArtTheme.DrawRow(new Rect(2, cy, w - 24, 34), m.IsRead == 0);
            string readMark = m.IsRead != 0 ? "" : "● ";
            string attachMark = m.AttachNum > 0 ? $" [附件x{m.AttachNum}]" : "";
            GUIStyle richLabel = new GUIStyle(_labelStyle) { richText = true };

            string color = m.IsRead != 0 ? "grey" : "white";
            GUI.Label(new Rect(5, cy, w - 180, 28),
                $"<color={color}>{readMark}{m.Title}{attachMark}</color>", richLabel);
            GUI.Label(new Rect(5, cy + 16, w - 180, 18),
                $"<color=#888888>发件人: {m.SenderId}</color>", richLabel);

            if (GUI.Button(new Rect(w - 160, cy + 4, 50, 28), "阅读", _smallBtnStyle))
            {
                TrySend("mail_read", new MailReadReq { MailId = m.MailId });
            }
            if (GUI.Button(new Rect(w - 100, cy + 4, 50, 28), "删除", _smallBtnStyle))
            {
                TrySend("mail_delete", new MailDeleteReq { MailId = m.MailId });
            }
            cy += 40;
        }
        GUI.EndScrollView();
    }

    private void DrawMailDetail(float x, float y, float w, float h)
    {
        UIArtTheme.DrawInset(new Rect(x - 6, y - 6, w + 12, h + 12));
        if (GUI.Button(new Rect(x, y, 60, 24), "← 返回", _smallBtnStyle))
        {
            _showDetail = false;
            RequestData();
            return;
        }
        y += 30;
        h -= 30;

        GUI.Label(new Rect(x, y, w, 22), _currentDetail.Title, _headerStyle); y += 24;
        GUI.Label(new Rect(x, y, w, 20), $"发件人: {_currentDetail.SenderId}    时间: {_currentDetail.CreateTime}", _labelStyle); y += 22;

        // 内容
        GUI.Label(new Rect(x, y, w, 18), "内容:", _labelStyle); y += 20;
        float contentH = Mathf.Min(h - 120, 120);
        _detailScroll = GUI.BeginScrollView(new Rect(x, y, w, contentH), _detailScroll, new Rect(0, 0, w - 20, 200));
        GUI.Label(new Rect(0, 0, w - 20, 200), _currentDetail.Content, _contentStyle);
        GUI.EndScrollView();
        y += contentH + 8;

        // 附件
        if (_currentDetail.Attachments.Count > 0)
        {
            GUI.Label(new Rect(x, y, w, 20), "附件:", _headerStyle); y += 22;
            bool hasUnclaimed = false;
            foreach (var att in _currentDetail.Attachments)
            {
                string claimed = att.IsClaimed != 0 ? " (已领取)" : "";
                string itemName = ClientStaticData.GetItemName(att.ItemId);
                GUI.Label(new Rect(x + 10, y, w, 20), $"{itemName} x{att.Count}{claimed}", _labelStyle);
                y += 20;
                if (att.IsClaimed == 0) hasUnclaimed = true;
            }
            y += 5;
            if (hasUnclaimed)
            {
                if (GUI.Button(new Rect(x, y, 100, 28), "领取附件", _smallBtnStyle))
                {
                    TrySend("mail_claim", new MailClaimReq { MailId = _currentDetail.MailId });
                }
            }
        }
    }

    // --- 回调 ---
    private void OnMailList(MailListRes res)
    {
        _mails.Clear();
        foreach (var m in res.Mails)
            _mails.Add(m);
        // 按 mail_id 降序排列（新邮件在前）
        _mails.Sort((a, b) => b.MailId.CompareTo(a.MailId));
    }

    private void OnMailRead(MailReadRes res)
    {
        if (res.Code == 0 && res.Detail != null)
        {
            _currentDetail = res.Detail;
            _showDetail = true;
            _detailScroll = Vector2.zero;
        }
        else
        {
            SetStatus(res.Msg);
        }
    }

    private void OnMailClaim(MailClaimRes res)
    {
        SetStatus(res.Msg);
        if (res.Code == 0 && _currentDetail != null)
        {
            if (BagPanel.Instance != null)
                BagPanel.Instance.RequestData();
            // 重新读取以刷新附件状态
            TrySend("mail_read", new MailReadReq { MailId = _currentDetail.MailId });
        }
    }

    private void OnMailDelete(MailDeleteRes res)
    {
        SetStatus(res.Msg);
        if (res.Code == 0) RequestData();
    }

    private void OnMailNotify(MailNotify notify)
    {
        if (notify.Mail != null)
        {
            int idx = _mails.FindIndex(m => m.MailId == notify.Mail.MailId);
            if (idx >= 0)
            {
                _mails[idx] = notify.Mail;
            }
            else
            {
                _mails.Insert(0, notify.Mail);
            }
            _mails.Sort((a, b) => b.MailId.CompareTo(a.MailId));
            SetStatus("收到新邮件！");
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

        _mails.Clear();
        _currentDetail = null;
        _showDetail = false;
        _listScroll = Vector2.zero;
        _detailScroll = Vector2.zero;
    }
}
