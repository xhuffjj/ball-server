using System;
using System.Collections;
using Game;
using UnityEngine;

/// <summary>
/// 客户端会话状态：管理登录态、base_info、ACK 和断线重连。
/// </summary>
public class ClientSession : MonoBehaviour
{
    public static ClientSession Instance { get; private set; }

    public bool IsLoggedIn => _isLoggedIn;
    public bool CanAttemptReconnect => _isLoggedIn && _playerId > 0 && !string.IsNullOrEmpty(_token);
    public bool IsReconnecting => _reconnectRoutine != null || _awaitingReconnectResponse;
    public int PlayerId => _playerId;
    public string Token => _token ?? "";
    public int LastAck => _lastAck;
    public BaseInfoRes CurrentBaseInfo { get; private set; }

    public event Action<BaseInfoRes> OnBaseInfoUpdated;
    public event Action<bool> OnReconnectStateChanged;
    public event Action<string> OnReconnectNotice;

    private const int MaxReconnectAttempts = 6;
    private const float RetryDelaySeconds = 1.5f;
    private const float ConnectTimeoutSeconds = 4f;
    private const float ResponseTimeoutSeconds = 4f;

    private bool _isLoggedIn = false;
    private int _playerId = 0;
    private string _token = "";
    private int _lastAck = 0;

    private Coroutine _reconnectRoutine;
    private bool _awaitingReconnectResponse = false;
    private bool _reconnectSucceeded = false;

    void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(gameObject);
            return;
        }

        Instance = this;
        DontDestroyOnLoad(gameObject);
    }

    void Start()
    {
        if (NetworkManager.Instance != null)
        {
            NetworkManager.Instance.OnMessageReceived += OnRawMessage;
            NetworkManager.Instance.OnConnectionChanged += OnConnectionChanged;
        }

        var proto = ProtocolHandler.Instance;
        if (proto == null)
        {
            Debug.LogError("[ClientSession] ProtocolHandler 未初始化，会话回调注册失败");
            return;
        }

        proto.On<BaseInfoRes>("base_info", OnBaseInfoRes);
        proto.On<ReconnectRes>("reconnect", OnReconnectRes);
    }

    void OnDestroy()
    {
        if (NetworkManager.Instance != null)
        {
            NetworkManager.Instance.OnMessageReceived -= OnRawMessage;
            NetworkManager.Instance.OnConnectionChanged -= OnConnectionChanged;
        }

        if (Instance == this)
        {
            Instance = null;
        }
    }

    public void BeginAuthenticatedSession(int playerId, string token)
    {
        _isLoggedIn = true;
        _playerId = playerId;
        _token = token ?? "";
        _lastAck = 0;
        CurrentBaseInfo = null;
        StopReconnectRoutine();
        PublishReconnectState(false);
        RequestBaseInfo();
    }

    public void EndSession()
    {
        StopReconnectRoutine();
        _awaitingReconnectResponse = false;
        _reconnectSucceeded = false;
        _isLoggedIn = false;
        _playerId = 0;
        _token = "";
        _lastAck = 0;
        CurrentBaseInfo = null;
        PublishReconnectState(false);
    }

    public bool ShouldPreserveStateOnDisconnect()
    {
        var net = NetworkManager.Instance;
        return CanAttemptReconnect && net != null && !net.LastDisconnectWasUserInitiated;
    }

    public void RequestBaseInfo()
    {
        var net = NetworkManager.Instance;
        if (!_isLoggedIn || net == null || !net.IsConnected)
            return;

        net.Send("base_info", new BaseInfoReq());
    }

    private void OnRawMessage(string cmd, byte[] body)
    {
        if (!_isLoggedIn)
            return;

        if (cmd == "login_first" || cmd == "login_second" || cmd == "register" || cmd == "reconnect")
            return;

        _lastAck++;
    }

    private void OnConnectionChanged(bool connected)
    {
        if (connected)
            return;

        if (!ShouldPreserveStateOnDisconnect())
            return;

        if (_reconnectRoutine == null)
        {
            _reconnectRoutine = StartCoroutine(ReconnectRoutine());
        }
    }

    private void OnBaseInfoRes(BaseInfoRes res)
    {
        CurrentBaseInfo = res;
        OnBaseInfoUpdated?.Invoke(res);
    }

    private void OnReconnectRes(ReconnectRes res)
    {
        if (!_awaitingReconnectResponse)
            return;

        _awaitingReconnectResponse = false;
        _reconnectSucceeded = res.Code == 0;

        if (_reconnectSucceeded)
        {
            PublishNotice("重连成功");
        }
        else
        {
            PublishNotice("会话恢复失败，继续重试...");
        }
    }

    private IEnumerator ReconnectRoutine()
    {
        PublishReconnectState(true);
        PublishNotice("连接断开，正在尝试重连...");

        for (int attempt = 1; attempt <= MaxReconnectAttempts; attempt++)
        {
            if (!CanAttemptReconnect)
                break;

            if (attempt > 1)
                yield return new WaitForSecondsRealtime(RetryDelaySeconds);

            var net = NetworkManager.Instance;
            if (net == null)
                break;

            PublishNotice($"正在重连 ({attempt}/{MaxReconnectAttempts})...");
            net.Connect(net.ServerIP, net.ServerPort);

            float connectDeadline = Time.realtimeSinceStartup + ConnectTimeoutSeconds;
            while (!net.IsConnected && Time.realtimeSinceStartup < connectDeadline)
            {
                yield return null;
            }

            if (!net.IsConnected)
                continue;

            _awaitingReconnectResponse = true;
            _reconnectSucceeded = false;
            net.Send("reconnect", new ReconnectReq
            {
                Playerid = _playerId,
                Token = _token,
                LastAck = _lastAck
            });

            float responseDeadline = Time.realtimeSinceStartup + ResponseTimeoutSeconds;
            while (_awaitingReconnectResponse && net.IsConnected && Time.realtimeSinceStartup < responseDeadline)
            {
                yield return null;
            }

            if (_reconnectSucceeded)
            {
                _reconnectRoutine = null;
                PublishReconnectState(false);
                RequestBaseInfo();
                yield break;
            }

            _awaitingReconnectResponse = false;
            if (net.IsConnected)
            {
                net.Disconnect(false);
            }
        }

        _reconnectRoutine = null;
        PublishNotice("重连失败，请重新登录");
        EndSession();

        var finalNet = NetworkManager.Instance;
        if (finalNet != null)
        {
            finalNet.Disconnect(true);
        }
    }

    private void StopReconnectRoutine()
    {
        if (_reconnectRoutine != null)
        {
            StopCoroutine(_reconnectRoutine);
            _reconnectRoutine = null;
        }
    }

    private void PublishReconnectState(bool active)
    {
        OnReconnectStateChanged?.Invoke(active);
    }

    private void PublishNotice(string notice)
    {
        if (string.IsNullOrEmpty(notice))
            return;

        OnReconnectNotice?.Invoke(notice);
    }
}
