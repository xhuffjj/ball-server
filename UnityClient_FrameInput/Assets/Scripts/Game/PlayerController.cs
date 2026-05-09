using UnityEngine;
using Game;

/// <summary>
/// 玩家控制器 - 采集目标点与技能输入，并每 50ms 聚合成一帧发送。
/// 方向输入也按 50ms tick 采样，让本地立即执行和服务端输入频率保持一致。
/// </summary>
public class PlayerController : MonoBehaviour
{
    public static PlayerController Instance { get; private set; }
    public bool IsActive => _active;

    private const float SendIntervalSeconds = 0.05f;
    private const float KeyboardTargetDistance = GameManager.MAP_SIZE * 2f;
    private const KeyCode DebugDisconnectKey = KeyCode.F9;
    private const KeyCode DebugBattleDisconnectKey = KeyCode.F10;

    private bool _active = false;
    private float _sendTimer = 0f;
    private float _targetX = 0f;
    private float _targetY = 0f;
    private bool _moving = false;
    private bool _queuedSplit = false;
    private bool _queuedSpit = false;

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

    void Update()
    {
        if (!_active) return;
        if (GameManager.Instance == null) return;
        if (GameManager.Instance.MyPlayerId == 0) return;
        if (BattleNetworkManager.Instance == null || !BattleNetworkManager.Instance.IsReadyForInput) return;

        if (TryTriggerDebugBattleDisconnect())
        {
            return;
        }

        if (TryTriggerDebugDisconnect())
        {
            return;
        }

        UpdateActionInput();

        _sendTimer += Time.deltaTime;
        while (_sendTimer >= SendIntervalSeconds)
        {
            _sendTimer -= SendIntervalSeconds;
            UpdateDirectionInput();
            SendInputFrame();
        }
    }

    public void Activate()
    {
        _active = true;
    }

    public void Deactivate()
    {
        _active = false;
        _sendTimer = 0f;
        _targetX = 0f;
        _targetY = 0f;
        _moving = false;
        _queuedSplit = false;
        _queuedSpit = false;
    }

    private void UpdateDirectionInput()
    {
        if (IsStopPressedThisFrame())
        {
            _moving = false;
            return;
        }

        if (TryGetMouseTarget(out Vector2 mouseTarget))
        {
            _targetX = mouseTarget.x;
            _targetY = mouseTarget.y;
            _moving = true;
            return;
        }

        if (TryGetKeyboardTarget(out Vector2 keyboardTarget))
        {
            _targetX = keyboardTarget.x;
            _targetY = keyboardTarget.y;
            _moving = true;
            return;
        }

        _moving = false;
    }

    private void UpdateActionInput()
    {
        if (IsSplitPressedThisFrame())
        {
            _queuedSplit = true;
        }

        if (IsSpitPressedThisFrame())
        {
            _queuedSpit = true;
        }
    }

    private bool TryTriggerDebugDisconnect()
    {
        if (!IsDebugDisconnectPressedThisFrame())
        {
            return false;
        }

        if (NetworkManager.Instance == null || !NetworkManager.Instance.IsConnected)
        {
            return false;
        }

        Debug.Log("[PlayerController] F9 调试断线：主动关闭客户端连接并触发自动重连");
        NetworkManager.Instance.Disconnect(false);
        return true;
    }

    private bool TryTriggerDebugBattleDisconnect()
    {
        if (!IsDebugBattleDisconnectPressedThisFrame())
        {
            return false;
        }

        if (BattleNetworkManager.Instance == null)
        {
            return false;
        }

        return BattleNetworkManager.Instance.TriggerDebugDisconnectBySilence();
    }

    private void SendInputFrame()
    {
        if (GameManager.Instance == null || BattleNetworkManager.Instance == null)
        {
            return;
        }

        int inputSeq = GameManager.Instance.RecordLocalInputSent(_targetX, _targetY, _moving, _queuedSplit, _queuedSpit);
        var req = new InputFrameReq
        {
            InputSeq = inputSeq,
            TargetX = _targetX,
            TargetY = _targetY,
            Moving = _moving,
            Split = _queuedSplit,
            Spit = _queuedSpit
        };

        BattleNetworkManager.Instance.SendMessage("input_frame", req);
        _queuedSplit = false;
        _queuedSpit = false;
    }

    private bool TryGetMouseTarget(out Vector2 target)
    {
        target = Vector2.zero;
        if (!IsMouseControlPressed())
        {
            return false;
        }

        Camera cam = Camera.main;
        if (cam == null)
        {
            return false;
        }

        Vector3 mouseScreen = GetMouseScreenPosition();
        mouseScreen.z = Mathf.Abs(cam.transform.position.z);
        Vector3 mouseWorld = cam.ScreenToWorldPoint(mouseScreen);
        target = ClampToMap(new Vector2(mouseWorld.x / GameManager.SCALE, mouseWorld.y / GameManager.SCALE));
        return true;
    }

    private bool TryGetKeyboardTarget(out Vector2 target)
    {
        target = Vector2.zero;
        float kx = 0f;
        float ky = 0f;
        if (IsMoveUpPressed()) ky += 1f;
        if (IsMoveDownPressed()) ky -= 1f;
        if (IsMoveLeftPressed()) kx -= 1f;
        if (IsMoveRightPressed()) kx += 1f;

        if (kx == 0f && ky == 0f)
        {
            return false;
        }

        Vector2 dir = new Vector2(kx, ky).normalized;
        Vector2 anchor = GetMovementAnchor();
        target = ClampToMap(anchor + dir * KeyboardTargetDistance);
        return true;
    }

    private Vector2 GetMovementAnchor()
    {
        Camera cam = Camera.main;
        if (cam != null)
        {
            return new Vector2(
                cam.transform.position.x / GameManager.SCALE,
                cam.transform.position.y / GameManager.SCALE
            );
        }

        BallEntity myBall = FindMyBall();
        if (myBall != null)
        {
            return new Vector2(
                myBall.transform.position.x / GameManager.SCALE,
                myBall.transform.position.y / GameManager.SCALE
            );
        }

        return Vector2.zero;
    }

    private Vector2 ClampToMap(Vector2 target)
    {
        return new Vector2(
            Mathf.Clamp(target.x, 0f, GameManager.MAP_SIZE),
            Mathf.Clamp(target.y, 0f, GameManager.MAP_SIZE)
        );
    }

    private BallEntity FindMyBall()
    {
        if (GameManager.Instance == null) return null;
        return GameManager.Instance.GetMyBall();
    }

    private Vector3 GetMouseScreenPosition()
    {
        try
        {
            return Input.mousePosition;
        }
        catch
        {
            return Vector3.zero;
        }
    }

    private bool IsMoveUpPressed()
    {
        return SafeGetKey(KeyCode.W) || SafeGetKey(KeyCode.UpArrow);
    }

    private bool IsMoveDownPressed()
    {
        return SafeGetKey(KeyCode.S) || SafeGetKey(KeyCode.DownArrow);
    }

    private bool IsMoveLeftPressed()
    {
        return SafeGetKey(KeyCode.A) || SafeGetKey(KeyCode.LeftArrow);
    }

    private bool IsMoveRightPressed()
    {
        return SafeGetKey(KeyCode.D) || SafeGetKey(KeyCode.RightArrow);
    }

    private bool IsMouseControlPressed()
    {
        return SafeGetMouseButton(0) || SafeGetMouseButton(1);
    }

    private bool IsSplitPressedThisFrame()
    {
        return SafeGetKeyDown(KeyCode.Space);
    }

    private bool IsSpitPressedThisFrame()
    {
        return SafeGetKeyDown(KeyCode.Q);
    }

    private bool IsStopPressedThisFrame()
    {
        return SafeGetKeyDown(KeyCode.X);
    }

    private bool IsDebugDisconnectPressedThisFrame()
    {
        return SafeGetKeyDown(DebugDisconnectKey);
    }

    private bool IsDebugBattleDisconnectPressedThisFrame()
    {
        return SafeGetKeyDown(DebugBattleDisconnectKey);
    }

    private bool SafeGetKey(KeyCode key)
    {
        try
        {
            return Input.GetKey(key);
        }
        catch
        {
            return false;
        }
    }

    private bool SafeGetKeyDown(KeyCode key)
    {
        try
        {
            return Input.GetKeyDown(key);
        }
        catch
        {
            return false;
        }
    }

    private bool SafeGetMouseButton(int button)
    {
        try
        {
            return Input.GetMouseButton(button);
        }
        catch
        {
            return false;
        }
    }

    void OnGUI()
    {
        if (!_active) return;

        GUIStyle style = new GUIStyle(GUI.skin.label)
        {
            fontSize = 14,
            alignment = TextAnchor.LowerRight
        };
        style.normal.textColor = new Color(1f, 1f, 1f, 0.6f);
        GUI.Label(
            new Rect(Screen.width - 420, Screen.height - 94, 400, 80),
            "按住鼠标指定目标点 / WASD 移动\nSpace 分裂  Q 吐孢子  X 停止  F9 模拟 TCP 断线  F10 模拟 KCP 断线",
            style
        );
    }
}
