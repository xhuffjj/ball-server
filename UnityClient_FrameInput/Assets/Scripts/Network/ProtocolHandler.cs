using System;
using System.Collections.Generic;
using Google.Protobuf;
using UnityEngine;

/// <summary>
/// 协议处理器 - 负责消息注册、解析和分发。
/// </summary>
public class ProtocolHandler : MonoBehaviour
{
    public static ProtocolHandler Instance { get; private set; }

    [SerializeField] private bool VerboseProtocolLog = false;

    private readonly Dictionary<string, Func<byte[], IMessage>> _parsers = new Dictionary<string, Func<byte[], IMessage>>();
    private readonly Dictionary<string, List<Action<IMessage>>> _handlers = new Dictionary<string, List<Action<IMessage>>>();

    void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(gameObject);
            return;
        }

        Instance = this;
        DontDestroyOnLoad(gameObject);
        RegisterAllParsers();
    }

    void Start()
    {
        if (NetworkManager.Instance != null)
        {
            NetworkManager.Instance.OnMessageReceived += DispatchRawMessage;
        }
    }

    void OnDestroy()
    {
        if (NetworkManager.Instance != null)
        {
            NetworkManager.Instance.OnMessageReceived -= DispatchRawMessage;
        }

        if (Instance == this)
        {
            Instance = null;
        }
    }

    private void RegisterAllParsers()
    {
        RegisterParser<Game.LoginFirstRes>("login_first");
        RegisterParser<Game.LoginSecondRes>("login_second");
        RegisterParser<Game.RegisterRes>("register");
        RegisterParser<Game.BattleAuthRes>("battle_auth");
        RegisterParser<Game.JoinMatchRes>("join_match");
        RegisterParser<Game.CancelMatchRes>("cancel_match");
        RegisterParser<Game.MatchStatusRes>("match_status");
        RegisterParser<Game.MatchFoundNotify>("match_found");
        RegisterParser<Game.PrepareRes>("prepare");
        RegisterParser<Game.RoomPrepareNotify>("room_prepare");
        RegisterParser<Game.BattleConnectNotify>("battle_connect");
        RegisterParser<Game.RoomDismissNotify>("room_dismiss");
        RegisterParser<Game.BattleResultNotify>("battle_result");

        RegisterParser<Game.SceneSnapshot>("scene_snapshot");
        RegisterParser<Game.FrameUpdate>("frame_update");

        RegisterParser<Game.AchieveListRes>("achieve_list");
        RegisterParser<Game.AchieveClaimRes>("achieve_claim");
        RegisterParser<Game.AchieveNotify>("achieve_notify");

        RegisterParser<Game.WorkRes>("work");
        RegisterParser<Game.BagListRes>("baglist");
        RegisterParser<Game.UseItemRes>("use_item");

        RegisterParser<Game.MailListRes>("mail_list");
        RegisterParser<Game.MailReadRes>("mail_read");
        RegisterParser<Game.MailClaimRes>("mail_claim");
        RegisterParser<Game.MailDeleteRes>("mail_delete");
        RegisterParser<Game.MailNotify>("mail_notify");

        RegisterParser<Game.FriendListRes>("friend_list");
        RegisterParser<Game.FriendInfoRes>("friend_info");
        RegisterParser<Game.FriendPendingRes>("friend_pending_list");
        RegisterParser<Game.FriendAddRes>("friend_add");
        RegisterParser<Game.FriendAcceptRes>("friend_accept");
        RegisterParser<Game.FriendRejectRes>("friend_reject");
        RegisterParser<Game.FriendDeleteRes>("friend_delete");

        RegisterParser<Game.BaseInfoRes>("base_info");
        RegisterParser<Game.ReconnectRes>("reconnect");
    }

    private void RegisterParser<T>(string cmd) where T : IMessage<T>, new()
    {
        var parser = new MessageParser<T>(() => new T());
        _parsers[cmd] = bytes => parser.ParseFrom(bytes);
    }

    public void On<T>(string cmd, Action<T> handler) where T : IMessage
    {
        if (!_handlers.TryGetValue(cmd, out List<Action<IMessage>> list))
        {
            list = new List<Action<IMessage>>();
            _handlers[cmd] = list;
        }

        list.Add(msg => handler((T)msg));
    }

    public void Off(string cmd)
    {
        _handlers.Remove(cmd);
    }

    public bool TryParse(string cmd, byte[] body, out IMessage msg, out string err)
    {
        msg = null;
        err = null;

        if (!_parsers.TryGetValue(cmd, out Func<byte[], IMessage> parser))
        {
            err = "未注册解析器";
            return false;
        }

        try
        {
            msg = parser(body);
            return true;
        }
        catch (Exception e)
        {
            err = e.Message;
            return false;
        }
    }

    public void DispatchRawMessage(string cmd, byte[] body)
    {
        if (!TryParse(cmd, body, out IMessage msg, out string err))
        {
            if (err == "未注册解析器")
            {
                Debug.LogWarning($"[Proto] 未注册的命令: {cmd}");
            }
            else
            {
                Debug.LogError($"[Proto] 解析失败: {cmd}, Error: {err}");
            }
            return;
        }

        if (VerboseProtocolLog)
        {
            Debug.Log($"[Proto] 解析成功: {cmd} -> {msg}");
        }

        if (!_handlers.TryGetValue(cmd, out List<Action<IMessage>> list))
        {
            return;
        }

        foreach (Action<IMessage> handler in list)
        {
            handler(msg);
        }
    }
}
