using System.Collections.Generic;
using UnityEngine;
using Game;

/// <summary>
/// 游戏管理器 - 管理战斗场景中的 cell、food 和 spore。
/// </summary>
public class GameManager : MonoBehaviour
{
    public static GameManager Instance { get; private set; }

    public const float MAP_SIZE = 1000f;
    public const float SCALE = 0.3f;

    private const int RUNTIME_LAYER = 2;
    private const float SERVER_TICK_SECONDS = 0.05f;
    private const float CELL_BASE_SPEED = 5f;
    private const float CELL_MIN_SPEED = 1f;
    private const float SERVER_MOVE_STEP = 0.2f;
    private const float REMOTE_SMOOTH_SPEED = 10f;
    private const int MAX_LOCAL_CELLS = 16;
    private const float MIN_SPLIT_SIZE = 4f;
    private const float MIN_SPIT_SIZE = 3f;
    private const float SPIT_SPORE_SIZE = 1f;
    private const float SPLIT_BOOST = 10f;
    private const float SPIT_INIT_SPEED = 15f;
    private const int REMOTE_INTERP_DELAY_TICKS = 2;
    private const int REMOTE_MAX_BUFFER_STATES = 8;
    private const float SPLIT_FRICTION = 0.85f;
    private const float SPORE_FRICTION = 0.9f;
    private const float BOOST_STOP_EPSILON = 0.01f;
    private const float LOCAL_RECONCILE_IGNORE_ERROR = 0.12f;
    private const float LOCAL_RECONCILE_HARD_SNAP_ERROR = 1.4f;
    private const float LOCAL_RECONCILE_SOFT_FACTOR = 0.28f;
    private const float LOCAL_RECONCILE_MAX_STEP = 0.50f;
    private const int LOCAL_SELF_COLLISION_ITERS = 3;
    private const int LOCAL_LOW_DETAIL_CELL_THRESHOLD = 8;
    private const float LOCAL_VISUAL_POS_SMOOTH_SPEED = 18f;
    private const float LOCAL_VISUAL_SIZE_SMOOTH_SPEED = 12f;
    private const float LOCAL_VISUAL_POS_DEADZONE = 0.02f;
    private const float LOCAL_VISUAL_SIZE_DEADZONE = 0.02f;
    private const float LOCAL_VISUAL_HARD_SNAP_DISTANCE = 3f;
    private const float LATENCY_SAMPLE_SMOOTH = 0.35f;
    private const float MAX_ONE_WAY_LATENCY_SECONDS = 0.30f;

    private const float CAMERA_ORTHO_MIN = 10f;
    private const float CAMERA_ORTHO_MAX = 26f;
    private const float CAMERA_Z_NEAR = -10f;
    private const float CAMERA_Z_FAR = -24f;
    private const float CAMERA_POS_SMOOTH_SPEED = 8f;
    private const float CAMERA_SIZE_SMOOTH_SPEED = 6f;
    private const float CAMERA_POS_DEADZONE = 0.0025f;
    private const float CAMERA_SIZE_DEADZONE = 0.003f;
    private const float CAMERA_EDGE_MARGIN = 2.4f;
    private const float FOOD_VISUAL_MARGIN_FACTOR = 0.35f;
    private const float FOOD_VISUAL_MIN_MARGIN_MAP = 8f;
    private const int FOOD_POOL_PREWARM = 96;

    private const int BG_TEX_RES = 512;
    private const int SOFT_SPRITE_RES = 128;
    private const int AMBIENT_PARTICLE_COUNT = 90;

    private static readonly Vector2[] LocalOverlapDirs = new Vector2[]
    {
        new Vector2(1f, 0f),
        new Vector2(0.70710678f, 0.70710678f),
        new Vector2(0f, 1f),
        new Vector2(-0.70710678f, 0.70710678f),
        new Vector2(-1f, 0f),
        new Vector2(-0.70710678f, -0.70710678f),
        new Vector2(0f, -1f),
        new Vector2(0.70710678f, -0.70710678f),
    };

    private sealed class RemoteCellState
    {
        public int Tick;
        public float X;
        public float Y;
        public float Size;
        public float ProtectedTimerTicks;
    }

    private sealed class CellView
    {
        public int CellId;
        public long SortKey;
        public long StableKey;
        public int PlayerId;
        public float ServerX;
        public float ServerY;
        public float RenderX;
        public float RenderY;
        public float VisualX;
        public float VisualY;
        public float Size;
        public float VisualSize;
        public float ProtectedTimerTicks;
        public float BoostVx;
        public float BoostVy;
        public float LastDirX = 1f;
        public float LastDirY = 0f;
        public bool RenderInitialized;
        public bool VisualInitialized;
        public bool IsPredicted;
        public int PredictedActionSeq;
        public long PredictedParentStableKey;
        public bool PendingRemove;
        public int RemoveTick;
        public readonly List<RemoteCellState> RemoteStates = new List<RemoteCellState>(REMOTE_MAX_BUFFER_STATES);
        public BallEntity Entity;
    }

    private sealed class FoodView
    {
        public int Id;
        public float X;
        public float Y;
        public FoodEntity Entity;
    }

    private sealed class SporeView
    {
        public int Id;
        public float X;
        public float Y;
        public float Vx;
        public float Vy;
        public bool IsPredicted;
        public int PredictedActionSeq;
        public long PredictedSourceStableKey;
        public int OwnerPlayerId;
        public int SourceCellId;
        public bool HasExplicitVelocity;
        public bool HasAuthoritativeSnapshot;
        public float LastSnapshotX;
        public float LastSnapshotY;
        public int LastSnapshotTick;
        public SporeEntity Entity;
    }

    private sealed class PendingInput
    {
        public int Seq;
        public float TargetX;
        public float TargetY;
        public bool Moving;
        public bool Split;
        public bool Spit;
        public float SentAt;
        public readonly Dictionary<long, Vector2> CellDirs = new Dictionary<long, Vector2>();
    }

    public int MyPlayerId { get; private set; }

    private readonly Dictionary<int, CellView> _cells = new Dictionary<int, CellView>();
    private readonly Dictionary<int, FoodView> _foods = new Dictionary<int, FoodView>();
    private readonly Dictionary<int, SporeView> _spores = new Dictionary<int, SporeView>();
    private readonly List<PendingInput> _pendingInputs = new List<PendingInput>();
    private readonly HashSet<int> _incomingCellIds = new HashSet<int>();
    private readonly HashSet<int> _incomingSporeIds = new HashSet<int>();
    private readonly List<int> _cellIdsToRemove = new List<int>();
    private readonly List<int> _sporeIdsToRemove = new List<int>();
    private readonly Stack<FoodEntity> _foodEntityPool = new Stack<FoodEntity>();
    private readonly List<int> _foodIdsToRecycle = new List<int>();
    private readonly List<CellView> _ownedCellsAllBuffer = new List<CellView>(MAX_LOCAL_CELLS);
    private readonly List<CellView> _ownedCellsNoPredictedBuffer = new List<CellView>(MAX_LOCAL_CELLS);

    private int _nextInputSeq = 0;
    private int _latestAckedInputSeq = 0;
    private int _latestServerTick = 0;
    private float _latestServerTickReceivedAt = 0f;
    private float _estimatedOneWayLatencySeconds = SERVER_TICK_SECONDS * 0.5f;
    private float _authoritativeTargetX = 0f;
    private float _authoritativeTargetY = 0f;
    private bool _authoritativeMoving = false;
    private float _localTargetX = 0f;
    private float _localTargetY = 0f;
    private bool _localMoving = false;
    private int _lastLocalReconcileFrame = -1;
    private int _nextPredictedCellId = -1;
    private int _nextPredictedSporeId = -1;
    private long _nextLocalCellSortKey = 1;
    private long _nextLocalStableKey = 1;

    private Camera _mainCamera;
    private GameObject _sceneVisualRoot;
    private Transform _foodVisualRoot;
    private static Sprite _cachedBackgroundSprite;
    private static Sprite _cachedSoftCircleSprite;
    private static Material _cachedLineMaterial;

    private bool _inScene = false;
    private string _infoText = "";
    private GUIStyle _infoStyle;

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
        RegisterHandlers();
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

        if (Instance == this)
        {
            Instance = null;
        }
    }

    void Update()
    {
        if (!_inScene) return;

        float dt = Time.deltaTime;
        if (dt > 0f)
        {
            UpdateLocalCells(dt);
            UpdateRemoteCells(dt);
            UpdateSporeSimulation(dt);
            UpdateCellVisualStates(dt);
        }

        RefreshVisuals();
        UpdateInfoText();
    }

    void LateUpdate()
    {
        if (!_inScene) return;

        if (_mainCamera == null)
        {
            EnsureMainCamera();
            if (_mainCamera == null) return;
        }

        if (!TryGetMyCameraTarget(out Vector3 targetPos, out float targetOrtho))
        {
            return;
        }
        float size01 = Mathf.InverseLerp(CAMERA_ORTHO_MIN, CAMERA_ORTHO_MAX, targetOrtho);
        float targetZ = Mathf.Lerp(CAMERA_Z_NEAR, CAMERA_Z_FAR, size01);
        targetPos.z = targetZ;

        float posLerp = 1f - Mathf.Exp(-CAMERA_POS_SMOOTH_SPEED * Time.deltaTime);
        float sizeLerp = 1f - Mathf.Exp(-CAMERA_SIZE_SMOOTH_SPEED * Time.deltaTime);

        Vector3 curPos = _mainCamera.transform.position;
        Vector3 delta = targetPos - curPos;
        if (delta.sqrMagnitude <= CAMERA_POS_DEADZONE * CAMERA_POS_DEADZONE)
        {
            _mainCamera.transform.position = targetPos;
        }
        else
        {
            _mainCamera.transform.position = Vector3.Lerp(curPos, targetPos, posLerp);
        }

        float curSize = _mainCamera.orthographicSize;
        if (Mathf.Abs(curSize - targetOrtho) <= CAMERA_SIZE_DEADZONE)
        {
            _mainCamera.orthographicSize = targetOrtho;
        }
        else
        {
            _mainCamera.orthographicSize = Mathf.Lerp(curSize, targetOrtho, sizeLerp);
        }
    }

    void OnGUI()
    {
        if (!_inScene) return;

        if (_infoStyle == null)
        {
            _infoStyle = new GUIStyle(GUI.skin.label)
            {
                fontSize = 16,
                alignment = TextAnchor.UpperLeft
            };
            _infoStyle.normal.textColor = Color.white;
        }

        GUI.Label(new Rect(10, 10, 720, 30), _infoText, _infoStyle);

        BallEntity myBall = GetMyBall();
        if (myBall != null)
        {
            GUI.Label(new Rect(10, 35, 260, 30), $"主视角球大小: {myBall.BallSize:F1}", _infoStyle);
        }
    }

    private void RegisterHandlers()
    {
        ProtocolHandler proto = ProtocolHandler.Instance;
        if (proto == null)
        {
            Debug.LogError("[Game] ProtocolHandler 未初始化，战斗消息注册失败");
            return;
        }

        proto.On<SceneSnapshot>("scene_snapshot", OnSceneSnapshot);
        proto.On<FrameUpdate>("frame_update", OnFrameUpdate);
    }

    public void OnEnteredScene()
    {
        _inScene = true;
        ResetBattleState();
        SetupScene();
    }

    public void ExitBattleScene()
    {
        ResetSceneState();
    }

    public void SetMyPlayerId(int playerId)
    {
        if (playerId <= 0)
        {
            return;
        }

        MyPlayerId = playerId;
        MarkOwnedCellsAsMine();
        Debug.Log($"[Game] 设置 MyPlayerId = {MyPlayerId}");
    }

    private void TryApplyMyPlayerIdFromSession()
    {
        if (MyPlayerId != 0)
        {
            return;
        }

        if (ClientSession.Instance == null)
        {
            return;
        }

        int playerId = ClientSession.Instance.PlayerId;
        if (playerId > 0)
        {
            SetMyPlayerId(playerId);
        }
    }

    public void SetLocalInputTarget(float targetX, float targetY, bool moving)
    {
        _localTargetX = Mathf.Clamp(targetX, 0f, MAP_SIZE);
        _localTargetY = Mathf.Clamp(targetY, 0f, MAP_SIZE);
        _localMoving = moving;
    }

    public int RecordLocalInputSent(float targetX, float targetY, bool moving)
    {
        return RecordLocalInputSent(targetX, targetY, moving, false, false);
    }

    public int RecordLocalInputSent(float targetX, float targetY, bool moving, bool split, bool spit)
    {
        targetX = Mathf.Clamp(targetX, 0f, MAP_SIZE);
        targetY = Mathf.Clamp(targetY, 0f, MAP_SIZE);
        int seq = ++_nextInputSeq;
        PendingInput input = new PendingInput
        {
            Seq = seq,
            TargetX = targetX,
            TargetY = targetY,
            Moving = moving,
            Split = split,
            Spit = spit,
            SentAt = Time.unscaledTime
        };
        CapturePendingInputCellDirs(input);
        _pendingInputs.Add(input);
        _localTargetX = targetX;
        _localTargetY = targetY;
        _localMoving = moving;
        ApplyImmediateLocalPrediction(input);
        return seq;
    }

    private void OnSceneSnapshot(SceneSnapshot notify)
    {
        EnsureSceneReady();
        ClearBattleEntities();

        float receiveTime = Time.unscaledTime;
        _latestServerTick = notify.Tick;
        _latestServerTickReceivedAt = receiveTime;
        TryApplyMyPlayerIdFromSession();
        TryInferMyPlayerIdFromCells(notify.Cells);

        ApplyCellList(notify.Cells, true);

        foreach (Food food in notify.Foods)
        {
            AddOrUpdateFood(food.Id, food.X, food.Y);
        }

        ApplySporeList(notify.Spores);

        int ackSeq = _latestAckedInputSeq;
        UpdateAuthoritativeTimingAndControl(ackSeq, receiveTime);
        ReconcileLocalPrediction(receiveTime, ackSeq);
        FinalizeAck(ackSeq);
        SnapCameraToMyTargetImmediate();
        RefreshVisuals();

        if (PlayerController.Instance != null)
        {
            PlayerController.Instance.Activate();
        }
    }

    private void OnFrameUpdate(FrameUpdate notify)
    {
        EnsureSceneReady();
        float receiveTime = Time.unscaledTime;
        _latestServerTick = notify.Tick;
        _latestServerTickReceivedAt = receiveTime;
        TryApplyMyPlayerIdFromSession();
        TryInferMyPlayerIdFromCells(notify.Cells);

        foreach (Food food in notify.NewFoods)
        {
            AddOrUpdateFood(food.Id, food.X, food.Y);
        }
        foreach (int foodId in notify.EatenFoodIds)
        {
            RemoveFood(foodId);
        }

        ApplyNewCellMetadata(notify.NewCells);
        foreach (SelfNewSporeInfo spore in notify.NewSpores)
        {
            ApplyServerNewSpore(spore);
        }
        ApplySporeList(notify.Spores);
        ApplyCellList(notify.Cells, false);
        int ackSeq = notify.Ack;
        UpdateAuthoritativeTimingAndControl(ackSeq, receiveTime);
        ReconcileLocalPrediction(receiveTime, ackSeq);
        FinalizeAck(ackSeq);
    }

    private void EnsureSceneReady()
    {
        if (_inScene && _sceneVisualRoot != null)
        {
            return;
        }

        _inScene = true;
        SetupScene();
    }

    private void ApplyCellList(IEnumerable<CellInfo> cells, bool forceSnap)
    {
        _incomingCellIds.Clear();
        foreach (CellInfo cell in cells)
        {
            _incomingCellIds.Add(cell.CellId);
            ApplyAuthoritativeCellInfo(cell, forceSnap);
        }

        _cellIdsToRemove.Clear();
        foreach (KeyValuePair<int, CellView> pair in _cells)
        {
            if (!_incomingCellIds.Contains(pair.Key))
            {
                CellView view = pair.Value;
                if (forceSnap || view.PlayerId == MyPlayerId)
                {
                    _cellIdsToRemove.Add(pair.Key);
                    continue;
                }

                if (!view.PendingRemove)
                {
                    view.PendingRemove = true;
                    view.RemoveTick = _latestServerTick;
                }
            }
        }

        foreach (int cellId in _cellIdsToRemove)
        {
            RemoveCell(cellId);
        }
    }

    private void ApplyAuthoritativeCellInfo(CellInfo info, bool forceSnap)
    {
        if (!_cells.TryGetValue(info.CellId, out CellView view))
        {
            view = new CellView
            {
                CellId = info.CellId,
                SortKey = info.CellId,
                StableKey = info.CellId
            };
            _cells[info.CellId] = view;
        }

        bool playerChanged = view.PlayerId != info.Playerid;
        view.SortKey = info.CellId;
        if (view.StableKey == 0L)
        {
            view.StableKey = info.CellId;
        }
        view.PlayerId = info.Playerid;
        view.ServerX = info.X;
        view.ServerY = info.Y;
        view.Size = info.Size;
        view.ProtectedTimerTicks = info.ProtectedTimer;
        view.IsPredicted = false;
        view.PredictedActionSeq = 0;
        view.PredictedParentStableKey = 0L;
        view.PendingRemove = false;
        _nextLocalCellSortKey = System.Math.Max(_nextLocalCellSortKey, (long)info.CellId + 1L);
        _nextLocalStableKey = System.Math.Max(_nextLocalStableKey, (long)info.CellId + 1L);

        if (forceSnap || playerChanged)
        {
            view.RemoteStates.Clear();
        }

        if (view.PlayerId != MyPlayerId)
        {
            BufferRemoteCellState(view, _latestServerTick, info.X, info.Y, info.Size, info.ProtectedTimer);
        }

        if (!view.RenderInitialized || forceSnap || playerChanged)
        {
            view.RenderX = info.X;
            view.RenderY = info.Y;
            view.RenderInitialized = true;
            SnapCellVisualState(view);
        }
    }

    private void ApplySporeList(IEnumerable<SporeInfo> spores)
    {
        _incomingSporeIds.Clear();
        foreach (SporeInfo spore in spores)
        {
            _incomingSporeIds.Add(spore.SporeId);
            ApplyAuthoritativeSporeSnapshot(spore);
        }

        _sporeIdsToRemove.Clear();
        foreach (KeyValuePair<int, SporeView> pair in _spores)
        {
            if (pair.Value.IsPredicted)
            {
                continue;
            }

            if (!_incomingSporeIds.Contains(pair.Key))
            {
                _sporeIdsToRemove.Add(pair.Key);
            }
        }

        foreach (int sporeId in _sporeIdsToRemove)
        {
            RemoveSpore(sporeId);
        }
    }

    private void ApplyAuthoritativeSporeSnapshot(SporeInfo info)
    {
        if (!_spores.TryGetValue(info.SporeId, out SporeView spore))
        {
            spore = new SporeView { Id = info.SporeId };
            _spores[info.SporeId] = spore;
        }

        if (!spore.HasExplicitVelocity && spore.HasAuthoritativeSnapshot && _latestServerTick > spore.LastSnapshotTick)
        {
            int tickDelta = _latestServerTick - spore.LastSnapshotTick;
            float moveWindow = Mathf.Max(SERVER_MOVE_STEP, tickDelta * SERVER_MOVE_STEP);
            spore.Vx = (info.X - spore.LastSnapshotX) / moveWindow;
            spore.Vy = (info.Y - spore.LastSnapshotY) / moveWindow;
        }

        spore.X = info.X;
        spore.Y = info.Y;
        ClampInsideMap(ref spore.X, ref spore.Y);
        spore.IsPredicted = false;
        spore.HasAuthoritativeSnapshot = true;
        spore.LastSnapshotX = info.X;
        spore.LastSnapshotY = info.Y;
        spore.LastSnapshotTick = _latestServerTick;
    }

    private void ApplyNewCellMetadata(IEnumerable<SelfNewCell> newCells)
    {
        foreach (SelfNewCell newCell in newCells)
        {
            CellView view = null;
            if (newCell.Playerid == MyPlayerId && newCell.ActionSeq > 0 && newCell.ParentCellId > 0)
            {
                view = TryAdoptPredictedSplitCell(newCell);
            }

            if (view == null && !_cells.TryGetValue(newCell.CellId, out view))
            {
                view = new CellView
                {
                    CellId = newCell.CellId,
                    SortKey = newCell.CellId,
                    StableKey = newCell.CellId,
                    PlayerId = newCell.Playerid,
                    ServerX = newCell.X,
                    ServerY = newCell.Y,
                    RenderX = newCell.X,
                    RenderY = newCell.Y,
                    VisualX = newCell.X,
                    VisualY = newCell.Y,
                    Size = newCell.Size,
                    VisualSize = newCell.Size,
                    RenderInitialized = true,
                    VisualInitialized = true
                };
                _cells[newCell.CellId] = view;
            }

            view.SortKey = newCell.CellId;
            if (view.StableKey == 0L)
            {
                view.StableKey = newCell.CellId;
            }
            view.PlayerId = newCell.Playerid;
            view.IsPredicted = false;
            view.PredictedActionSeq = 0;
            view.PredictedParentStableKey = 0L;
            view.ServerX = newCell.X;
            view.ServerY = newCell.Y;
            view.Size = newCell.Size;
            view.BoostVx = newCell.BoostVx;
            view.BoostVy = newCell.BoostVy;
            _nextLocalCellSortKey = System.Math.Max(_nextLocalCellSortKey, (long)newCell.CellId + 1L);
            _nextLocalStableKey = System.Math.Max(_nextLocalStableKey, (long)newCell.CellId + 1L);
            if (Mathf.Abs(newCell.BoostVx) > BOOST_STOP_EPSILON || Mathf.Abs(newCell.BoostVy) > BOOST_STOP_EPSILON)
            {
                Vector2 dir = new Vector2(newCell.BoostVx, newCell.BoostVy).normalized;
                view.LastDirX = dir.x;
                view.LastDirY = dir.y;
            }
            if (view.PlayerId != MyPlayerId)
            {
                BufferRemoteCellState(view, _latestServerTick, newCell.X, newCell.Y, newCell.Size, view.ProtectedTimerTicks);
            }
            if (!view.RenderInitialized)
            {
                view.RenderX = newCell.X;
                view.RenderY = newCell.Y;
                view.RenderInitialized = true;
                SnapCellVisualState(view);
            }
        }
    }

    private CellView TryAdoptPredictedSplitCell(SelfNewCell newCell)
    {
        CellView parentView = FindOwnedCellById(newCell.ParentCellId);
        if (parentView == null)
        {
            return null;
        }

        CellView predictedChild = null;
        foreach (CellView cell in _cells.Values)
        {
            if (!cell.IsPredicted || cell.PlayerId != MyPlayerId)
            {
                continue;
            }

            if (cell.PredictedActionSeq != newCell.ActionSeq)
            {
                continue;
            }

            if (cell.PredictedParentStableKey != parentView.StableKey)
            {
                continue;
            }

            predictedChild = cell;
            break;
        }

        if (predictedChild == null)
        {
            return null;
        }

        if (_cells.TryGetValue(newCell.CellId, out CellView existing) && existing != predictedChild)
        {
            if (existing.Entity != null)
            {
                Destroy(existing.Entity.gameObject);
            }
            _cells.Remove(existing.CellId);
        }

        _cells.Remove(predictedChild.CellId);
        predictedChild.CellId = newCell.CellId;
        predictedChild.SortKey = newCell.CellId;
        predictedChild.PlayerId = newCell.Playerid;
        predictedChild.ServerX = newCell.X;
        predictedChild.ServerY = newCell.Y;
        predictedChild.IsPredicted = false;
        predictedChild.PredictedActionSeq = 0;
        predictedChild.PredictedParentStableKey = 0L;
        _cells[newCell.CellId] = predictedChild;
        return predictedChild;
    }

    private CellView FindOwnedCellById(int cellId)
    {
        if (cellId == 0)
        {
            return null;
        }

        if (_cells.TryGetValue(cellId, out CellView direct) && direct.PlayerId == MyPlayerId)
        {
            return direct;
        }

        foreach (CellView cell in _cells.Values)
        {
            if (cell.CellId == cellId && cell.PlayerId == MyPlayerId)
            {
                return cell;
            }
        }

        return null;
    }

    private void AddOrUpdateFood(int id, float x, float y)
    {
        if (!_foods.TryGetValue(id, out FoodView food))
        {
            food = new FoodView { Id = id };
            _foods[id] = food;
        }

        food.X = x;
        food.Y = y;
    }

    private void AddOrUpdateSpore(int id, float x, float y, float vx, float vy)
    {
        AddOrUpdateSpore(id, x, y, vx, vy, false, 0, 0, 0, 0L);
    }

    private void AddOrUpdateSpore(int id, float x, float y, float vx, float vy, bool isPredicted, int ownerPlayerId, int predictedActionSeq, int sourceCellId, long predictedSourceStableKey)
    {
        if (!_spores.TryGetValue(id, out SporeView spore))
        {
            spore = new SporeView { Id = id };
            _spores[id] = spore;
        }

        spore.X = x;
        spore.Y = y;
        spore.Vx = vx;
        spore.Vy = vy;
        spore.IsPredicted = isPredicted;
        spore.PredictedActionSeq = predictedActionSeq;
        spore.PredictedSourceStableKey = predictedSourceStableKey;
        spore.OwnerPlayerId = ownerPlayerId;
        spore.SourceCellId = sourceCellId;
        spore.HasExplicitVelocity = true;
        spore.HasAuthoritativeSnapshot = !isPredicted;
        spore.LastSnapshotX = x;
        spore.LastSnapshotY = y;
        spore.LastSnapshotTick = isPredicted ? 0 : _latestServerTick;
    }

    private void RemoveCell(int cellId)
    {
        if (_cells.TryGetValue(cellId, out CellView cell))
        {
            if (cell.Entity != null)
            {
                Destroy(cell.Entity.gameObject);
            }
            _cells.Remove(cellId);
        }
    }

    private void RemoveFood(int foodId)
    {
        if (_foods.TryGetValue(foodId, out FoodView food))
        {
            ReleaseFoodVisual(food);
            _foods.Remove(foodId);
        }
    }

    private void RemoveSpore(int sporeId)
    {
        if (_spores.TryGetValue(sporeId, out SporeView spore))
        {
            if (spore.Entity != null)
            {
                Destroy(spore.Entity.gameObject);
            }
            _spores.Remove(sporeId);
        }
    }

    private PendingInput FindPendingInput(int seq)
    {
        if (seq <= 0)
        {
            return null;
        }

        for (int i = 0; i < _pendingInputs.Count; i++)
        {
            if (_pendingInputs[i].Seq == seq)
            {
                return _pendingInputs[i];
            }
        }

        return null;
    }

    private void UpdateAuthoritativeTimingAndControl(int maxAck, float receiveTime)
    {
        PendingInput ackInput = FindPendingInput(maxAck);
        if (ackInput != null)
        {
            float sample = Mathf.Clamp((receiveTime - ackInput.SentAt) * 0.5f, 0f, MAX_ONE_WAY_LATENCY_SECONDS);
            _estimatedOneWayLatencySeconds = Mathf.Lerp(_estimatedOneWayLatencySeconds, sample, LATENCY_SAMPLE_SMOOTH);
            _authoritativeTargetX = ackInput.TargetX;
            _authoritativeTargetY = ackInput.TargetY;
            _authoritativeMoving = ackInput.Moving;
        }
        else if (maxAck == 0 && _latestAckedInputSeq == 0)
        {
            _authoritativeTargetX = 0f;
            _authoritativeTargetY = 0f;
            _authoritativeMoving = false;
        }
    }

    private void FinalizeAck(int maxAck)
    {
        if (maxAck > _latestAckedInputSeq)
        {
            _latestAckedInputSeq = maxAck;
        }
        RemoveAckedInputs(maxAck);
    }

    private void RemoveAckedInputs(int ackSeq)
    {
        for (int i = _pendingInputs.Count - 1; i >= 0; i--)
        {
            if (_pendingInputs[i].Seq <= ackSeq)
            {
                _pendingInputs.RemoveAt(i);
            }
        }
    }

    private void CapturePendingInputCellDirs(PendingInput input)
    {
        input.CellDirs.Clear();
        List<CellView> ownedCells = CollectOwnedCellsSorted(true);
        if (ownedCells == null)
        {
            return;
        }

        foreach (CellView cell in ownedCells)
        {
            input.CellDirs[cell.StableKey] = new Vector2(cell.LastDirX, cell.LastDirY);
        }
    }

    private void ApplyImmediateLocalPrediction(PendingInput input)
    {
        if (MyPlayerId == 0)
        {
            return;
        }

        ApplyControlSnapshotToOwnedCells(input.TargetX, input.TargetY, input.Moving);

        bool changed = false;
        if (input.Split)
        {
            changed |= PredictSplitAction(input);
        }
        if (input.Spit)
        {
            changed |= PredictSpitAction(input);
        }

        if (changed)
        {
            RefreshVisuals();
        }
    }

    private void ReconcileLocalPrediction(float receiveTime, int maxAck)
    {
        if (MyPlayerId == 0)
        {
            return;
        }

        RollbackOwnedCellsToAuthoritative();
        RemovePredictedLocalArtifacts();

        float baseTime = Mathf.Max(0f, receiveTime - _estimatedOneWayLatencySeconds);
        float currentTime = baseTime;
        float activeTargetX = _authoritativeTargetX;
        float activeTargetY = _authoritativeTargetY;
        bool activeMoving = _authoritativeMoving;

        for (int i = 0; i < _pendingInputs.Count; i++)
        {
            PendingInput input = _pendingInputs[i];
            if (input.Seq <= maxAck)
            {
                continue;
            }

            float applyTime = Mathf.Clamp(input.SentAt + _estimatedOneWayLatencySeconds, baseTime, receiveTime);
            SimulateLocalPredictionSegment(currentTime, applyTime, activeTargetX, activeTargetY, activeMoving);

            ApplyControlSnapshotToOwnedCells(input.TargetX, input.TargetY, input.Moving);
            activeTargetX = input.TargetX;
            activeTargetY = input.TargetY;
            activeMoving = input.Moving;

            if (input.Split)
            {
                PredictSplitAction(input);
            }
            if (input.Spit)
            {
                PredictSpitAction(input);
            }

            currentTime = applyTime;
        }

        SimulateLocalPredictionSegment(currentTime, receiveTime, activeTargetX, activeTargetY, activeMoving);
        _localTargetX = activeTargetX;
        _localTargetY = activeTargetY;
        _localMoving = activeMoving;
        _lastLocalReconcileFrame = Time.frameCount;
    }

    private void RollbackOwnedCellsToAuthoritative()
    {
        foreach (CellView view in _cells.Values)
        {
            if (view.PlayerId != MyPlayerId || view.IsPredicted)
            {
                continue;
            }

            view.RenderX = view.ServerX;
            view.RenderY = view.ServerY;
            view.RenderInitialized = true;
            ClampInsideMap(ref view.RenderX, ref view.RenderY);
        }
    }

    private void RemovePredictedLocalArtifacts()
    {
        _cellIdsToRemove.Clear();
        foreach (KeyValuePair<int, CellView> pair in _cells)
        {
            if (pair.Value.PlayerId == MyPlayerId && pair.Value.IsPredicted)
            {
                _cellIdsToRemove.Add(pair.Key);
            }
        }

        foreach (int cellId in _cellIdsToRemove)
        {
            RemoveCell(cellId);
        }

        List<int> sporeIdsToRemove = null;
        foreach (SporeView spore in _spores.Values)
        {
            if (!spore.IsPredicted)
            {
                continue;
            }

            if (sporeIdsToRemove == null)
            {
                sporeIdsToRemove = new List<int>();
            }
            sporeIdsToRemove.Add(spore.Id);
        }

        if (sporeIdsToRemove == null)
        {
            return;
        }

        foreach (int sporeId in sporeIdsToRemove)
        {
            RemoveSpore(sporeId);
        }
    }

    private void SimulateLocalPredictionSegment(float startTime, float endTime, float targetX, float targetY, bool moving)
    {
        float dt = endTime - startTime;
        if (dt <= 0f)
        {
            return;
        }

        List<CellView> ownedCells = CollectOwnedCellsSorted(true);
        if (ownedCells != null)
        {
            foreach (CellView cell in ownedCells)
            {
                AdvanceCellMotion(cell, dt, targetX, targetY, moving);
            }
            ResolveLocalOwnedCellCollisions(ownedCells);
        }

        AdvancePredictedSpores(dt);
    }

    private void AdvancePredictedSpores(float dt)
    {
        float tickUnits = GetServerTickUnits(dt);
        float moveScale = GetServerMoveScale(dt);
        float friction = Mathf.Pow(SPORE_FRICTION, tickUnits);
        foreach (SporeView spore in _spores.Values)
        {
            if (!spore.IsPredicted)
            {
                continue;
            }

            spore.X += spore.Vx * moveScale;
            spore.Y += spore.Vy * moveScale;
            ClampInsideMap(ref spore.X, ref spore.Y);

            spore.Vx *= friction;
            spore.Vy *= friction;
            if (Mathf.Abs(spore.Vx) < BOOST_STOP_EPSILON) spore.Vx = 0f;
            if (Mathf.Abs(spore.Vy) < BOOST_STOP_EPSILON) spore.Vy = 0f;
        }
    }

    private List<CellView> CollectOwnedCellsSorted(bool includePredicted)
    {
        List<CellView> ownedCells = includePredicted ? _ownedCellsAllBuffer : _ownedCellsNoPredictedBuffer;
        ownedCells.Clear();
        foreach (CellView view in _cells.Values)
        {
            if (view.PlayerId != MyPlayerId || !view.RenderInitialized)
            {
                continue;
            }

            if (!includePredicted && view.IsPredicted)
            {
                continue;
            }

            ownedCells.Add(view);
        }

        if (ownedCells.Count == 0)
        {
            return null;
        }

        ownedCells.Sort((a, b) =>
        {
            int cmp = a.SortKey.CompareTo(b.SortKey);
            return cmp != 0 ? cmp : a.CellId.CompareTo(b.CellId);
        });
        return ownedCells;
    }

    private void ApplyControlSnapshotToOwnedCells(float targetX, float targetY, bool moving)
    {
        if (!moving)
        {
            return;
        }

        List<CellView> ownedCells = CollectOwnedCellsSorted(true);
        if (ownedCells == null)
        {
            return;
        }

        foreach (CellView cell in ownedCells)
        {
            float dx = targetX - cell.RenderX;
            float dy = targetY - cell.RenderY;
            float distSq = dx * dx + dy * dy;
            if (distSq <= 0.000001f)
            {
                continue;
            }

            float invDist = 1f / Mathf.Sqrt(distSq);
            cell.LastDirX = dx * invDist;
            cell.LastDirY = dy * invDist;
        }
    }

    private Vector2 GetActionDirForCell(CellView cell, PendingInput input)
    {
        if (input.Moving)
        {
            float dx = input.TargetX - cell.RenderX;
            float dy = input.TargetY - cell.RenderY;
            float distSq = dx * dx + dy * dy;
            if (distSq > 0.000001f)
            {
                float invDist = 1f / Mathf.Sqrt(distSq);
                return new Vector2(dx * invDist, dy * invDist);
            }
        }

        if (input.CellDirs.TryGetValue(cell.StableKey, out Vector2 storedDir) && storedDir.sqrMagnitude > 0.000001f)
        {
            return storedDir.normalized;
        }

        Vector2 currentDir = new Vector2(cell.LastDirX, cell.LastDirY);
        if (currentDir.sqrMagnitude > 0.000001f)
        {
            return currentDir.normalized;
        }

        return Vector2.right;
    }

    private bool PredictSplitAction(PendingInput input)
    {
        List<CellView> ownedCells = CollectOwnedCellsSorted(true);
        if (ownedCells == null || ownedCells.Count >= MAX_LOCAL_CELLS)
        {
            return false;
        }

        List<CellView> newCells = null;
        int totalCount = ownedCells.Count;
        foreach (CellView cell in ownedCells)
        {
            if (cell.Size < MIN_SPLIT_SIZE || totalCount >= MAX_LOCAL_CELLS)
            {
                continue;
            }

            float oldMass = cell.Size * cell.Size;
            float newSize = Mathf.Sqrt(oldMass * 0.5f);
            cell.Size = newSize;

            Vector2 dir = GetActionDirForCell(cell, input);
            CellView child = new CellView
            {
                CellId = _nextPredictedCellId--,
                SortKey = _nextLocalCellSortKey++,
                StableKey = _nextLocalStableKey++,
                PlayerId = MyPlayerId,
                ServerX = cell.RenderX,
                ServerY = cell.RenderY,
                RenderX = cell.RenderX,
                RenderY = cell.RenderY,
                VisualX = cell.RenderX,
                VisualY = cell.RenderY,
                Size = newSize,
                VisualSize = newSize,
                BoostVx = SPLIT_BOOST * dir.x,
                BoostVy = SPLIT_BOOST * dir.y,
                LastDirX = dir.x,
                LastDirY = dir.y,
                RenderInitialized = true,
                VisualInitialized = true,
                IsPredicted = true,
                PredictedActionSeq = input.Seq,
                PredictedParentStableKey = cell.StableKey
            };

            if (newCells == null)
            {
                newCells = new List<CellView>();
            }
            newCells.Add(child);
            totalCount++;
        }

        if (newCells == null)
        {
            return false;
        }

        foreach (CellView child in newCells)
        {
            _cells[child.CellId] = child;
        }
        return true;
    }

    private bool PredictSpitAction(PendingInput input)
    {
        List<CellView> ownedCells = CollectOwnedCellsSorted(true);
        if (ownedCells == null)
        {
            return false;
        }

        bool changed = false;
        float sporeMass = SPIT_SPORE_SIZE * SPIT_SPORE_SIZE;
        foreach (CellView cell in ownedCells)
        {
            if (cell.Size < MIN_SPIT_SIZE)
            {
                continue;
            }

            float oldMass = cell.Size * cell.Size;
            if (oldMass <= sporeMass)
            {
                continue;
            }

            cell.Size = Mathf.Sqrt(oldMass - sporeMass);
            Vector2 dir = GetActionDirForCell(cell, input);
            float sporeX = cell.RenderX + dir.x * cell.Size;
            float sporeY = cell.RenderY + dir.y * cell.Size;
            AddOrUpdateSpore(
                _nextPredictedSporeId--,
                sporeX,
                sporeY,
                SPIT_INIT_SPEED * dir.x,
                SPIT_INIT_SPEED * dir.y,
                true,
                MyPlayerId,
                input.Seq,
                cell.CellId,
                cell.StableKey
            );
            changed = true;
        }

        return changed;
    }

    private void ApplyServerNewSpore(SelfNewSporeInfo spore)
    {
        if (spore.OwnerPlayerid == MyPlayerId && spore.ActionSeq > 0)
        {
            long sourceStableKey = 0L;
            CellView sourceView = FindOwnedCellById(spore.SourceCellId);
            if (sourceView != null)
            {
                sourceStableKey = sourceView.StableKey;
            }

            SporeView predicted = FindPredictedSpore(spore.ActionSeq, spore.SourceCellId, sourceStableKey);
            if (predicted != null)
            {
                if (_spores.TryGetValue(spore.SporeId, out SporeView existing) && existing != predicted)
                {
                    RemoveSpore(predicted.Id);
                }
                else
                {
                    _spores.Remove(predicted.Id);
                    predicted.Id = spore.SporeId;
                    predicted.X = spore.X;
                    predicted.Y = spore.Y;
                    predicted.Vx = spore.Vx;
                    predicted.Vy = spore.Vy;
                    predicted.IsPredicted = false;
                    predicted.PredictedActionSeq = 0;
                    predicted.PredictedSourceStableKey = 0L;
                    predicted.OwnerPlayerId = spore.OwnerPlayerid;
                    predicted.SourceCellId = spore.SourceCellId;
                    predicted.HasExplicitVelocity = true;
                    predicted.HasAuthoritativeSnapshot = true;
                    predicted.LastSnapshotX = spore.X;
                    predicted.LastSnapshotY = spore.Y;
                    predicted.LastSnapshotTick = _latestServerTick;
                    _spores[spore.SporeId] = predicted;
                    return;
                }
            }
        }

        AddOrUpdateSpore(spore.SporeId, spore.X, spore.Y, spore.Vx, spore.Vy, false, spore.OwnerPlayerid, 0, spore.SourceCellId, 0L);
    }

    private SporeView FindPredictedSpore(int actionSeq, int sourceCellId, long sourceStableKey)
    {
        SporeView fallback = null;
        foreach (SporeView spore in _spores.Values)
        {
            if (!spore.IsPredicted || spore.PredictedActionSeq != actionSeq)
            {
                continue;
            }

            if (sourceStableKey != 0L && spore.PredictedSourceStableKey == sourceStableKey)
            {
                return spore;
            }

            if (sourceCellId != 0 && spore.SourceCellId == sourceCellId)
            {
                return spore;
            }

            if (fallback == null)
            {
                fallback = spore;
            }
        }

        return fallback;
    }

    private void UpdateLocalCells(float dt)
    {
        if (_lastLocalReconcileFrame == Time.frameCount)
        {
            return;
        }

        List<CellView> ownedCells = CollectOwnedCellsSorted(true);
        if (ownedCells == null)
        {
            return;
        }

        foreach (CellView view in ownedCells)
        {
            AdvanceCellMotion(view, dt, _localTargetX, _localTargetY, _localMoving);
        }
        ResolveLocalOwnedCellCollisions(ownedCells);
    }

    private void UpdateRemoteCells(float dt)
    {
        float renderTick = GetRemoteRenderTick();
        _cellIdsToRemove.Clear();
        foreach (CellView view in _cells.Values)
        {
            if (view.PlayerId == MyPlayerId || !view.RenderInitialized)
            {
                continue;
            }

            ApplyRemoteRenderState(view, renderTick, dt);
            if (view.PendingRemove && renderTick >= view.RemoveTick)
            {
                _cellIdsToRemove.Add(view.CellId);
            }
        }

        foreach (int cellId in _cellIdsToRemove)
        {
            RemoveCell(cellId);
        }
    }

    private void SnapCellVisualState(CellView view)
    {
        if (view == null || !view.RenderInitialized)
        {
            return;
        }

        view.VisualX = view.RenderX;
        view.VisualY = view.RenderY;
        view.VisualSize = view.Size;
        view.VisualInitialized = true;
    }

    private void UpdateCellVisualStates(float dt)
    {
        float posSmooth = 1f - Mathf.Exp(-LOCAL_VISUAL_POS_SMOOTH_SPEED * dt);
        float sizeSmooth = 1f - Mathf.Exp(-LOCAL_VISUAL_SIZE_SMOOTH_SPEED * dt);
        float hardSnapSq = LOCAL_VISUAL_HARD_SNAP_DISTANCE * LOCAL_VISUAL_HARD_SNAP_DISTANCE;

        foreach (CellView view in _cells.Values)
        {
            if (!view.RenderInitialized)
            {
                continue;
            }

            if (!view.VisualInitialized)
            {
                SnapCellVisualState(view);
                continue;
            }

            if (view.PlayerId != MyPlayerId)
            {
                view.VisualX = view.RenderX;
                view.VisualY = view.RenderY;
                view.VisualSize = view.Size;
                continue;
            }

            float dx = view.RenderX - view.VisualX;
            float dy = view.RenderY - view.VisualY;
            float distSq = dx * dx + dy * dy;
            if (distSq >= hardSnapSq)
            {
                view.VisualX = view.RenderX;
                view.VisualY = view.RenderY;
            }
            else if (distSq <= LOCAL_VISUAL_POS_DEADZONE * LOCAL_VISUAL_POS_DEADZONE)
            {
                view.VisualX = view.RenderX;
                view.VisualY = view.RenderY;
            }
            else
            {
                view.VisualX = Mathf.Lerp(view.VisualX, view.RenderX, posSmooth);
                view.VisualY = Mathf.Lerp(view.VisualY, view.RenderY, posSmooth);
            }

            if (Mathf.Abs(view.VisualSize - view.Size) <= LOCAL_VISUAL_SIZE_DEADZONE)
            {
                view.VisualSize = view.Size;
            }
            else
            {
                view.VisualSize = Mathf.Lerp(view.VisualSize, view.Size, sizeSmooth);
            }
        }
    }

    private void ApplyRemoteRenderState(CellView view, float renderTick, float dt)
    {
        if (TrySampleRemoteCellState(view, renderTick, out float x, out float y, out float size, out float protectedTimerTicks))
        {
            view.RenderX = x;
            view.RenderY = y;
            view.Size = size;
            view.ProtectedTimerTicks = protectedTimerTicks;
            ClampInsideMap(ref view.RenderX, ref view.RenderY);
            return;
        }

        float smooth = 1f - Mathf.Exp(-REMOTE_SMOOTH_SPEED * dt);
        view.RenderX = Mathf.Lerp(view.RenderX, view.ServerX, smooth);
        view.RenderY = Mathf.Lerp(view.RenderY, view.ServerY, smooth);
        AdvanceCellBoost(view, dt);
        ClampInsideMap(ref view.RenderX, ref view.RenderY);
        TickProtectedTimer(view, dt);
    }

    private void UpdateSporeSimulation(float dt)
    {
        float tickUnits = GetServerTickUnits(dt);
        float moveScale = GetServerMoveScale(dt);
        float friction = Mathf.Pow(SPORE_FRICTION, tickUnits);
        foreach (SporeView spore in _spores.Values)
        {
            if (spore.IsPredicted && _lastLocalReconcileFrame == Time.frameCount)
            {
                continue;
            }

            spore.X += spore.Vx * moveScale;
            spore.Y += spore.Vy * moveScale;
            ClampInsideMap(ref spore.X, ref spore.Y);

            spore.Vx *= friction;
            spore.Vy *= friction;
            if (Mathf.Abs(spore.Vx) < BOOST_STOP_EPSILON) spore.Vx = 0f;
            if (Mathf.Abs(spore.Vy) < BOOST_STOP_EPSILON) spore.Vy = 0f;
        }
    }

    private void AdvanceCellMotion(CellView view, float dt, float targetX, float targetY, bool moving)
    {
        if (moving)
        {
            float dx = targetX - view.RenderX;
            float dy = targetY - view.RenderY;
            float dist = Mathf.Sqrt(dx * dx + dy * dy);
            if (dist > 0.0001f)
            {
                float invDist = 1f / dist;
                float speed = CalcCellSpeed(view.Size);
                float moveStep = Mathf.Min(speed * GetServerMoveScale(dt), dist);
                view.LastDirX = dx * invDist;
                view.LastDirY = dy * invDist;
                view.RenderX += dx * invDist * moveStep;
                view.RenderY += dy * invDist * moveStep;
            }
        }

        AdvanceCellBoost(view, dt);
        ClampInsideMap(ref view.RenderX, ref view.RenderY);
        TickProtectedTimer(view, dt);
    }

    private void AdvanceCellBoost(CellView view, float dt)
    {
        if (Mathf.Abs(view.BoostVx) < BOOST_STOP_EPSILON && Mathf.Abs(view.BoostVy) < BOOST_STOP_EPSILON)
        {
            view.BoostVx = 0f;
            view.BoostVy = 0f;
            return;
        }

        float tickUnits = GetServerTickUnits(dt);
        float moveScale = GetServerMoveScale(dt);
        view.RenderX += view.BoostVx * moveScale;
        view.RenderY += view.BoostVy * moveScale;

        float friction = Mathf.Pow(SPLIT_FRICTION, tickUnits);
        view.BoostVx *= friction;
        view.BoostVy *= friction;

        if (Mathf.Abs(view.BoostVx) < BOOST_STOP_EPSILON) view.BoostVx = 0f;
        if (Mathf.Abs(view.BoostVy) < BOOST_STOP_EPSILON) view.BoostVy = 0f;
    }

    private void TickProtectedTimer(CellView view, float dt)
    {
        if (view.ProtectedTimerTicks <= 0f)
        {
            view.ProtectedTimerTicks = 0f;
            return;
        }

        view.ProtectedTimerTicks = Mathf.Max(0f, view.ProtectedTimerTicks - dt / SERVER_TICK_SECONDS);
    }

    private float GetServerTickUnits(float dt)
    {
        return dt / SERVER_TICK_SECONDS;
    }

    private float GetServerMoveScale(float dt)
    {
        return SERVER_MOVE_STEP * GetServerTickUnits(dt);
    }

    private float GetRemoteRenderTick()
    {
        if (_latestServerTick <= 0)
        {
            return 0f;
        }

        float elapsedTicks = 0f;
        if (_latestServerTickReceivedAt > 0f)
        {
            elapsedTicks = Mathf.Max(0f, (Time.unscaledTime - _latestServerTickReceivedAt) / SERVER_TICK_SECONDS);
        }

        return _latestServerTick - REMOTE_INTERP_DELAY_TICKS + elapsedTicks;
    }

    private void BufferRemoteCellState(CellView view, int tick, float x, float y, float size, float protectedTimerTicks)
    {
        List<RemoteCellState> states = view.RemoteStates;
        int lastIndex = states.Count - 1;
        if (lastIndex >= 0 && states[lastIndex].Tick == tick)
        {
            RemoteCellState state = states[lastIndex];
            state.X = x;
            state.Y = y;
            state.Size = size;
            state.ProtectedTimerTicks = protectedTimerTicks;
            return;
        }

        states.Add(new RemoteCellState
        {
            Tick = tick,
            X = x,
            Y = y,
            Size = size,
            ProtectedTimerTicks = protectedTimerTicks
        });

        while (states.Count > REMOTE_MAX_BUFFER_STATES)
        {
            states.RemoveAt(0);
        }
    }

    private bool TrySampleRemoteCellState(CellView view, float renderTick, out float x, out float y, out float size, out float protectedTimerTicks)
    {
        x = view.ServerX;
        y = view.ServerY;
        size = view.Size;
        protectedTimerTicks = view.ProtectedTimerTicks;

        List<RemoteCellState> states = view.RemoteStates;
        if (states.Count == 0)
        {
            return false;
        }

        if (states.Count == 1 || renderTick <= states[0].Tick)
        {
            RemoteCellState state = states[0];
            x = state.X;
            y = state.Y;
            size = state.Size;
            protectedTimerTicks = state.ProtectedTimerTicks;
            return true;
        }

        int lastIndex = states.Count - 1;
        if (renderTick >= states[lastIndex].Tick)
        {
            RemoteCellState state = states[lastIndex];
            x = state.X;
            y = state.Y;
            size = state.Size;
            protectedTimerTicks = state.ProtectedTimerTicks;
            return true;
        }

        for (int i = 1; i < states.Count; i++)
        {
            RemoteCellState next = states[i];
            if (renderTick > next.Tick)
            {
                continue;
            }

            RemoteCellState prev = states[i - 1];
            float span = Mathf.Max(0.0001f, next.Tick - prev.Tick);
            float t = Mathf.Clamp01((renderTick - prev.Tick) / span);
            x = Mathf.Lerp(prev.X, next.X, t);
            y = Mathf.Lerp(prev.Y, next.Y, t);
            size = Mathf.Lerp(prev.Size, next.Size, t);
            protectedTimerTicks = Mathf.Lerp(prev.ProtectedTimerTicks, next.ProtectedTimerTicks, t);
            return true;
        }

        RemoteCellState latest = states[lastIndex];
        x = latest.X;
        y = latest.Y;
        size = latest.Size;
        protectedTimerTicks = latest.ProtectedTimerTicks;
        return true;
    }

    private void ResolveLocalOwnedCellCollisions(List<CellView> ownedCells)
    {
        if (ownedCells == null || ownedCells.Count <= 1)
        {
            return;
        }

        int iters = GetLocalCollisionIterations(ownedCells.Count);
        for (int iter = 0; iter < iters; iter++)
        {
            for (int i = 0; i < ownedCells.Count; i++)
            {
                CellView a = ownedCells[i];
                for (int j = i + 1; j < ownedCells.Count; j++)
                {
                    CellView b = ownedCells[j];
                    float dx = a.RenderX - b.RenderX;
                    float dy = a.RenderY - b.RenderY;
                    float distSq = dx * dx + dy * dy;
                    float dist = Mathf.Sqrt(distSq);
                    float minDist = a.Size + b.Size;
                    float overlap = minDist - dist;
                    if (overlap <= 0f)
                    {
                        continue;
                    }

                    float nx;
                    float ny;
                    if (dist < 0.001f)
                    {
                        Vector2 fallback = GetLocalOverlapFallbackDir(a.CellId, b.CellId);
                        nx = fallback.x;
                        ny = fallback.y;
                    }
                    else
                    {
                        float invDist = 1f / dist;
                        nx = dx * invDist;
                        ny = dy * invDist;
                    }

                    float pushX = nx * overlap * 0.5f;
                    float pushY = ny * overlap * 0.5f;
                    a.RenderX += pushX;
                    a.RenderY += pushY;
                    b.RenderX -= pushX;
                    b.RenderY -= pushY;
                    ClampInsideMap(ref a.RenderX, ref a.RenderY);
                    ClampInsideMap(ref b.RenderX, ref b.RenderY);
                }
            }
        }
    }

    private int GetLocalCollisionIterations(int ownedCellCount)
    {
        if (ownedCellCount <= 4)
        {
            return LOCAL_SELF_COLLISION_ITERS;
        }

        if (ownedCellCount <= LOCAL_LOW_DETAIL_CELL_THRESHOLD)
        {
            return 2;
        }

        return 1;
    }

    private Vector2 GetLocalOverlapFallbackDir(int cellIdA, int cellIdB)
    {
        int id1 = cellIdA;
        int id2 = cellIdB;
        if (id1 > id2)
        {
            int t = id1;
            id1 = id2;
            id2 = t;
        }

        long hash = (long)id1 * 73856093L + (long)id2 * 19349663L;
        int index = (int)((hash % LocalOverlapDirs.Length + LocalOverlapDirs.Length) % LocalOverlapDirs.Length);
        return LocalOverlapDirs[index];
    }

    private void SoftCorrectMyCell(CellView view, float targetX, float targetY)
    {
        if (!view.RenderInitialized)
        {
            view.RenderX = targetX;
            view.RenderY = targetY;
            view.RenderInitialized = true;
            return;
        }

        float dx = targetX - view.RenderX;
        float dy = targetY - view.RenderY;
        float error = Mathf.Sqrt(dx * dx + dy * dy);
        if (error <= LOCAL_RECONCILE_IGNORE_ERROR)
        {
            return;
        }

        bool hasPendingInput = _pendingInputs.Count > 0 || _localMoving;
        if (!hasPendingInput)
        {
            if (error >= LOCAL_RECONCILE_HARD_SNAP_ERROR)
            {
                view.RenderX = targetX;
                view.RenderY = targetY;
                return;
            }

            view.RenderX = Mathf.Lerp(view.RenderX, targetX, LOCAL_RECONCILE_SOFT_FACTOR);
            view.RenderY = Mathf.Lerp(view.RenderY, targetY, LOCAL_RECONCILE_SOFT_FACTOR);
            return;
        }

        float step = Mathf.Min(error * LOCAL_RECONCILE_SOFT_FACTOR, LOCAL_RECONCILE_MAX_STEP);
        if (step <= 0f)
        {
            return;
        }

        float invError = 1f / error;
        view.RenderX += dx * invError * step;
        view.RenderY += dy * invError * step;
    }

    private void RefreshVisuals()
    {
        int ownedCellCount = 0;
        int primaryOwnedCellId = 0;
        float primaryOwnedCellSize = -1f;
        foreach (CellView cell in _cells.Values)
        {
            if (cell.PlayerId != MyPlayerId || !cell.RenderInitialized)
            {
                continue;
            }

            ownedCellCount++;
            if (cell.Size > primaryOwnedCellSize)
            {
                primaryOwnedCellSize = cell.Size;
                primaryOwnedCellId = cell.CellId;
            }
        }

        foreach (CellView cell in _cells.Values)
        {
            CreateOrUpdateBallVisual(cell);
            if (cell.Entity != null)
            {
                bool useLowDetail = cell.PlayerId == MyPlayerId
                    && ownedCellCount >= LOCAL_LOW_DETAIL_CELL_THRESHOLD
                    && cell.CellId != primaryOwnedCellId;
                cell.Entity.SetLowDetailMode(useLowDetail);
                float visualX = cell.VisualInitialized ? cell.VisualX : cell.RenderX;
                float visualY = cell.VisualInitialized ? cell.VisualY : cell.RenderY;
                float visualSize = cell.VisualInitialized ? cell.VisualSize : cell.Size;
                cell.Entity.ApplyRenderState(visualX, visualY, visualSize);
                cell.Entity.SetProtectedTimer(Mathf.CeilToInt(cell.ProtectedTimerTicks));
            }
        }

        RefreshFoodVisuals();

        foreach (SporeView spore in _spores.Values)
        {
            CreateOrUpdateSporeVisual(spore);
        }
    }

    private void CreateOrUpdateBallVisual(CellView cell)
    {
        if (cell.Entity == null)
        {
            GameObject obj = new GameObject($"Cell_{cell.CellId}");
            obj.layer = RUNTIME_LAYER;
            BallEntity entity = obj.AddComponent<BallEntity>();
            float visualX = cell.VisualInitialized ? cell.VisualX : cell.RenderX;
            float visualY = cell.VisualInitialized ? cell.VisualY : cell.RenderY;
            float visualSize = cell.VisualInitialized ? cell.VisualSize : cell.Size;
            entity.Init(cell.CellId, cell.PlayerId, visualX, visualY, visualSize, cell.PlayerId == MyPlayerId);
            cell.Entity = entity;
        }

        if (cell.PlayerId == MyPlayerId && !cell.Entity.IsMyBall)
        {
            cell.Entity.SetAsMyBall();
        }
    }

    private void CreateOrUpdateFoodVisual(FoodView food)
    {
        if (food.Entity == null)
        {
            FoodEntity entity = AcquireFoodVisual();
            entity.Bind(food.Id, food.X, food.Y);
            food.Entity = entity;
            return;
        }

        if (food.Entity.FoodId != food.Id)
        {
            food.Entity.Bind(food.Id, food.X, food.Y);
            return;
        }

        food.Entity.SetWorldPosition(food.X, food.Y);
    }

    private void CreateOrUpdateSporeVisual(SporeView spore)
    {
        if (spore.Entity == null)
        {
            GameObject obj = new GameObject($"Spore_{spore.Id}");
            obj.layer = RUNTIME_LAYER;
            SporeEntity entity = obj.AddComponent<SporeEntity>();
            entity.Init(spore.Id, spore.X, spore.Y);
            spore.Entity = entity;
            return;
        }

        spore.Entity.SetWorldPosition(spore.X, spore.Y);
    }

    private void MarkOwnedCellsAsMine()
    {
        foreach (CellView cell in _cells.Values)
        {
            if (cell.PlayerId == MyPlayerId && cell.Entity != null && !cell.Entity.IsMyBall)
            {
                cell.Entity.SetAsMyBall();
            }
        }
    }

    private void TryInferMyPlayerIdFromCells(IEnumerable<CellInfo> cells)
    {
        if (MyPlayerId != 0)
        {
            return;
        }

        int candidate = 0;
        bool hasCandidate = false;
        foreach (CellInfo cell in cells)
        {
            if (!hasCandidate)
            {
                candidate = cell.Playerid;
                hasCandidate = true;
                continue;
            }

            if (cell.Playerid != candidate)
            {
                return;
            }
        }

        if (hasCandidate)
        {
            SetMyPlayerId(candidate);
        }
    }

    private void UpdateInfoText()
    {
        HashSet<int> playerIds = new HashSet<int>();
        int activeFoodVisuals = 0;
        foreach (CellView cell in _cells.Values)
        {
            playerIds.Add(cell.PlayerId);
        }
        foreach (FoodView food in _foods.Values)
        {
            if (food.Entity != null)
            {
                activeFoodVisuals++;
            }
        }

        _infoText = $"玩家数: {playerIds.Count}  Cells: {_cells.Count}  Spores: {_spores.Count}  Foods: {_foods.Count}  VisibleFoods: {activeFoodVisuals}  MyID: {MyPlayerId}  Tick: {_latestServerTick}  Pending: {_pendingInputs.Count}";
    }

    private float CalcCellSpeed(float size)
    {
        float safeSize = Mathf.Max(1f, size);
        return Mathf.Max(CELL_MIN_SPEED, CELL_BASE_SPEED / Mathf.Sqrt(safeSize));
    }

    private void ClampInsideMap(ref float x, ref float y)
    {
        x = Mathf.Clamp(x, 0f, MAP_SIZE);
        y = Mathf.Clamp(y, 0f, MAP_SIZE);
    }

    private void OnConnectionChanged(bool connected)
    {
        if (connected) return;
        if (ClientSession.Instance != null && ClientSession.Instance.ShouldPreserveStateOnDisconnect())
        {
            return;
        }

        ResetSceneState();
    }

    private void ResetSceneState()
    {
        _inScene = false;
        _infoText = "";
        MyPlayerId = 0;
        ResetInputTracking();
        ClearBattleEntities();

        if (PlayerController.Instance != null)
        {
            PlayerController.Instance.Deactivate();
        }

        if (_sceneVisualRoot != null)
        {
            Destroy(_sceneVisualRoot);
            _sceneVisualRoot = null;
        }
        _foodVisualRoot = null;
        _foodEntityPool.Clear();
        _foodIdsToRecycle.Clear();
    }

    private void ResetBattleState()
    {
        ResetInputTracking();
        ClearBattleEntities();
        _latestServerTick = 0;
        _latestServerTickReceivedAt = 0f;
        _infoText = "";

        if (PlayerController.Instance != null)
        {
            PlayerController.Instance.Deactivate();
        }
    }

    private void ResetInputTracking()
    {
        _pendingInputs.Clear();
        _nextInputSeq = 0;
        _latestAckedInputSeq = 0;
        _latestServerTickReceivedAt = 0f;
        _estimatedOneWayLatencySeconds = SERVER_TICK_SECONDS * 0.5f;
        _authoritativeTargetX = 0f;
        _authoritativeTargetY = 0f;
        _authoritativeMoving = false;
        _localTargetX = 0f;
        _localTargetY = 0f;
        _localMoving = false;
        _lastLocalReconcileFrame = -1;
        _nextPredictedCellId = -1;
        _nextPredictedSporeId = -1;
        _nextLocalCellSortKey = 1;
        _nextLocalStableKey = 1;
    }

    private void ClearBattleEntities()
    {
        foreach (CellView cell in _cells.Values)
        {
            if (cell.Entity != null)
            {
                Destroy(cell.Entity.gameObject);
            }
        }
        _cells.Clear();

        foreach (FoodView food in _foods.Values)
        {
            ReleaseFoodVisual(food);
        }
        _foods.Clear();
        _foodIdsToRecycle.Clear();

        foreach (SporeView spore in _spores.Values)
        {
            if (spore.Entity != null)
            {
                Destroy(spore.Entity.gameObject);
            }
        }
        _spores.Clear();
        _incomingCellIds.Clear();
        _incomingSporeIds.Clear();
        _cellIdsToRemove.Clear();
        _sporeIdsToRemove.Clear();
    }

    private void SetupScene()
    {
        EnsureMainCamera();
        if (_mainCamera == null) return;

        if (_sceneVisualRoot != null)
        {
            Destroy(_sceneVisualRoot);
        }
        _foodVisualRoot = null;
        _foodEntityPool.Clear();
        _foodIdsToRecycle.Clear();
        _sceneVisualRoot = new GameObject("SceneVisualRoot");
        SetLayerRecursively(_sceneVisualRoot, RUNTIME_LAYER);

        GameObject foodRoot = new GameObject("FoodVisualRoot");
        foodRoot.transform.SetParent(_sceneVisualRoot.transform, false);
        SetLayerRecursively(foodRoot, RUNTIME_LAYER);
        _foodVisualRoot = foodRoot.transform;

        _mainCamera.orthographic = true;
        _mainCamera.orthographicSize = CAMERA_ORTHO_MIN;
        _mainCamera.clearFlags = CameraClearFlags.SolidColor;
        _mainCamera.backgroundColor = new Color(0.02f, 0.03f, 0.08f);
        _mainCamera.cullingMask = 1 << RUNTIME_LAYER;
        _mainCamera.transform.position = new Vector3(MAP_SIZE * SCALE * 0.5f, MAP_SIZE * SCALE * 0.5f, CAMERA_Z_NEAR);

        CreateBackground(_sceneVisualRoot.transform);
        CreateNebula(_sceneVisualRoot.transform);
        CreateAmbientParticles(_sceneVisualRoot.transform);
        CreateGrid(_sceneVisualRoot.transform);
        CreateBorder(_sceneVisualRoot.transform);
        PrewarmFoodEntityPool(FOOD_POOL_PREWARM);
    }

    private void CreateGrid(Transform parent)
    {
        GameObject gridObj = new GameObject("Grid");
        gridObj.transform.SetParent(parent);
        SetLayerRecursively(gridObj, RUNTIME_LAYER);
        for (int i = 0; i <= (int)MAP_SIZE; i += 10)
        {
            CreateLine(
                gridObj.transform,
                new Vector3(0, i * SCALE, 0),
                new Vector3(MAP_SIZE * SCALE, i * SCALE, 0),
                new Color(0.30f, 0.45f, 0.65f, 0.18f)
            );
            CreateLine(
                gridObj.transform,
                new Vector3(i * SCALE, 0, 0),
                new Vector3(i * SCALE, MAP_SIZE * SCALE, 0),
                new Color(0.30f, 0.45f, 0.65f, 0.18f)
            );
        }
    }

    private void CreateLine(Transform parent, Vector3 start, Vector3 end, Color color)
    {
        GameObject lineObj = new GameObject("Line");
        lineObj.transform.SetParent(parent);
        lineObj.layer = RUNTIME_LAYER;
        LineRenderer lr = lineObj.AddComponent<LineRenderer>();
        Material lineMaterial = GetLineMaterial();
        if (lineMaterial != null)
        {
            lr.sharedMaterial = lineMaterial;
        }
        lr.startColor = color;
        lr.endColor = color;
        lr.startWidth = 0.02f;
        lr.endWidth = 0.02f;
        lr.positionCount = 2;
        lr.SetPosition(0, start);
        lr.SetPosition(1, end);
        lr.sortingOrder = -10;
    }

    private void CreateBorder(Transform parent)
    {
        GameObject border = new GameObject("Border");
        border.transform.SetParent(parent);
        SetLayerRecursively(border, RUNTIME_LAYER);
        float max = MAP_SIZE * SCALE;
        Color borderColor = new Color(0.3f, 0.6f, 1f, 0.8f);
        float width = 0.08f;

        CreateLine(border.transform, new Vector3(0, 0, 0), new Vector3(max, 0, 0), borderColor);
        CreateLine(border.transform, new Vector3(max, 0, 0), new Vector3(max, max, 0), borderColor);
        CreateLine(border.transform, new Vector3(max, max, 0), new Vector3(0, max, 0), borderColor);
        CreateLine(border.transform, new Vector3(0, max, 0), new Vector3(0, 0, 0), borderColor);

        GameObject glowBorder = new GameObject("BorderGlow");
        glowBorder.transform.SetParent(parent);
        SetLayerRecursively(glowBorder, RUNTIME_LAYER);
        Color glowColor = new Color(0.30f, 0.75f, 1.0f, 0.22f);
        CreateLine(glowBorder.transform, new Vector3(0, 0, 0), new Vector3(max, 0, 0), glowColor);
        CreateLine(glowBorder.transform, new Vector3(max, 0, 0), new Vector3(max, max, 0), glowColor);
        CreateLine(glowBorder.transform, new Vector3(max, max, 0), new Vector3(0, max, 0), glowColor);
        CreateLine(glowBorder.transform, new Vector3(0, max, 0), new Vector3(0, 0, 0), glowColor);
        foreach (LineRenderer lr in glowBorder.GetComponentsInChildren<LineRenderer>())
        {
            lr.startWidth = width * 2.2f;
            lr.endWidth = width * 2.2f;
            lr.sortingOrder = -12;
        }

        foreach (LineRenderer lr in border.GetComponentsInChildren<LineRenderer>())
        {
            lr.startWidth = width;
            lr.endWidth = width;
        }
    }

    private void CreateBackground(Transform parent)
    {
        float worldSize = MAP_SIZE * SCALE;
        Sprite sprite = GetBackgroundSprite();

        GameObject bgObj = new GameObject("Background");
        bgObj.transform.SetParent(parent);
        bgObj.layer = RUNTIME_LAYER;
        SpriteRenderer sr = bgObj.AddComponent<SpriteRenderer>();
        sr.sprite = sprite;
        sr.sortingOrder = -40;
        bgObj.transform.position = new Vector3(worldSize * 0.5f, worldSize * 0.5f, 0f);
        float sx = worldSize / Mathf.Max(0.001f, sprite.bounds.size.x);
        float sy = worldSize / Mathf.Max(0.001f, sprite.bounds.size.y);
        bgObj.transform.localScale = new Vector3(sx, sy, 1f);
    }

    private void CreateNebula(Transform parent)
    {
        float worldSize = MAP_SIZE * SCALE;
        Sprite sprite = GetSoftCircleSprite();
        Color[] colors = new Color[]
        {
            new Color(0.18f, 0.58f, 0.95f, 0.10f),
            new Color(0.08f, 0.82f, 0.74f, 0.08f),
            new Color(0.45f, 0.36f, 0.92f, 0.08f),
        };

        for (int i = 0; i < colors.Length; i++)
        {
            GameObject nebula = new GameObject($"Nebula_{i}");
            nebula.transform.SetParent(parent);
            nebula.layer = RUNTIME_LAYER;
            SpriteRenderer sr = nebula.AddComponent<SpriteRenderer>();
            sr.sprite = sprite;
            sr.color = colors[i];
            sr.sortingOrder = -30;

            float px = Random.Range(worldSize * 0.15f, worldSize * 0.85f);
            float py = Random.Range(worldSize * 0.15f, worldSize * 0.85f);
            float scale = Random.Range(worldSize * 0.42f, worldSize * 0.62f);
            nebula.transform.position = new Vector3(px, py, 0f);
            nebula.transform.localScale = new Vector3(scale, scale, 1f);
        }
    }

    private void CreateAmbientParticles(Transform parent)
    {
        float worldSize = MAP_SIZE * SCALE;
        Sprite sprite = GetSoftCircleSprite();
        Color[] palette = new Color[]
        {
            new Color(0.70f, 0.86f, 1.0f, 0.26f),
            new Color(0.58f, 1.0f, 0.92f, 0.24f),
            new Color(0.90f, 0.95f, 1.0f, 0.20f),
        };

        for (int i = 0; i < AMBIENT_PARTICLE_COUNT; i++)
        {
            GameObject p = new GameObject($"Ambient_{i}");
            p.transform.SetParent(parent);
            p.layer = RUNTIME_LAYER;
            SpriteRenderer sr = p.AddComponent<SpriteRenderer>();
            sr.sprite = sprite;
            sr.sortingOrder = -22;
            sr.color = palette[i % palette.Length];

            float size = Random.Range(0.07f, 0.22f);
            p.transform.position = new Vector3(Random.Range(0f, worldSize), Random.Range(0f, worldSize), 0f);
            p.transform.localScale = new Vector3(size, size, 1f);

            AmbientParticle drift = p.AddComponent<AmbientParticle>();
            drift.MinBound = Vector2.zero;
            drift.MaxBound = new Vector2(worldSize, worldSize);
            drift.Velocity = Random.insideUnitCircle * Random.Range(0.02f, 0.08f);
            drift.AlphaMin = 0.04f;
            drift.AlphaMax = sr.color.a;
            drift.TwinkleSpeed = Random.Range(0.8f, 2.2f);
        }
    }

    private static Sprite GetBackgroundSprite()
    {
        if (_cachedBackgroundSprite == null)
        {
            _cachedBackgroundSprite = ExternalArtLoader.LoadSprite("Art/Game/Background/bg_space_seamless.png");
            if (_cachedBackgroundSprite == null)
            {
                _cachedBackgroundSprite = CreateBackgroundSprite(BG_TEX_RES);
            }
        }
        return _cachedBackgroundSprite;
    }

    private static Sprite GetSoftCircleSprite()
    {
        if (_cachedSoftCircleSprite == null)
        {
            _cachedSoftCircleSprite = ExternalArtLoader.LoadSprite("Art/Game/Particles/light_01.png");
            if (_cachedSoftCircleSprite == null)
            {
                _cachedSoftCircleSprite = ExternalArtLoader.LoadSprite("Art/Game/Particles/circle_04.png");
            }
            if (_cachedSoftCircleSprite == null)
            {
                _cachedSoftCircleSprite = CreateSoftCircleSprite(SOFT_SPRITE_RES);
            }
        }
        return _cachedSoftCircleSprite;
    }

    private static Sprite CreateBackgroundSprite(int resolution)
    {
        Texture2D tex = new Texture2D(resolution, resolution, TextureFormat.RGBA32, false);
        tex.filterMode = FilterMode.Bilinear;
        tex.wrapMode = TextureWrapMode.Clamp;

        Color top = new Color(0.10f, 0.19f, 0.34f, 1f);
        Color bottom = new Color(0.02f, 0.04f, 0.10f, 1f);
        Vector2 center = new Vector2((resolution - 1) * 0.5f, (resolution - 1) * 0.5f);
        float radius = resolution * 0.7f;

        for (int y = 0; y < resolution; y++)
        {
            float t = y / (float)(resolution - 1);
            for (int x = 0; x < resolution; x++)
            {
                Color c = Color.Lerp(bottom, top, t);
                float dx = x - center.x;
                float dy = y - center.y;
                float dist01 = Mathf.Clamp01(Mathf.Sqrt(dx * dx + dy * dy) / radius);
                float vignette = Mathf.Lerp(1.08f, 0.70f, dist01 * dist01);
                float noise = 0.95f + Mathf.PerlinNoise(x * 0.03f, y * 0.03f) * 0.10f;
                c *= vignette * noise;
                tex.SetPixel(x, y, c);
            }
        }

        tex.Apply();
        return Sprite.Create(tex, new Rect(0, 0, resolution, resolution), new Vector2(0.5f, 0.5f), resolution);
    }

    private static Sprite CreateSoftCircleSprite(int resolution)
    {
        Texture2D tex = new Texture2D(resolution, resolution, TextureFormat.RGBA32, false);
        tex.filterMode = FilterMode.Bilinear;
        tex.wrapMode = TextureWrapMode.Clamp;

        float center = (resolution - 1) * 0.5f;
        float radius = resolution * 0.5f - 1f;

        for (int y = 0; y < resolution; y++)
        {
            for (int x = 0; x < resolution; x++)
            {
                float dx = x - center;
                float dy = y - center;
                float dist = Mathf.Sqrt(dx * dx + dy * dy);
                float t = Mathf.Clamp01(1f - dist / radius);
                t = t * t * (3f - 2f * t);
                tex.SetPixel(x, y, new Color(1f, 1f, 1f, t));
            }
        }

        tex.Apply();
        return Sprite.Create(tex, new Rect(0, 0, resolution, resolution), new Vector2(0.5f, 0.5f), resolution);
    }

    private void EnsureMainCamera()
    {
        if (_mainCamera != null) return;

        _mainCamera = Camera.main;
        if (_mainCamera == null)
        {
            _mainCamera = Object.FindObjectOfType<Camera>();
        }

        if (_mainCamera == null)
        {
            GameObject cameraObj = new GameObject("Main Camera");
            _mainCamera = cameraObj.AddComponent<Camera>();
        }

        if (!_mainCamera.CompareTag("MainCamera"))
        {
            _mainCamera.tag = "MainCamera";
        }
    }

    private void SnapCameraToMyTargetImmediate()
    {
        EnsureMainCamera();
        if (_mainCamera == null)
        {
            return;
        }

        if (!TryGetMyCameraTarget(out Vector3 targetPos, out float targetOrtho))
        {
            return;
        }

        float size01 = Mathf.InverseLerp(CAMERA_ORTHO_MIN, CAMERA_ORTHO_MAX, targetOrtho);
        float targetZ = Mathf.Lerp(CAMERA_Z_NEAR, CAMERA_Z_FAR, size01);
        targetPos.z = targetZ;
        _mainCamera.transform.position = targetPos;
        _mainCamera.orthographicSize = targetOrtho;
    }

    private bool TryGetMyCameraTarget(out Vector3 targetPos, out float targetOrtho)
    {
        targetPos = Vector3.zero;
        targetOrtho = CAMERA_ORTHO_MIN;
        if (MyPlayerId == 0)
        {
            return false;
        }

        float sumWeight = 0f;
        float weightedX = 0f;
        float weightedY = 0f;
        float largestSize = 0f;
        int ownedCount = 0;

        foreach (CellView cell in _cells.Values)
        {
            if (cell.PlayerId != MyPlayerId)
            {
                continue;
            }

            float visualX = cell.VisualInitialized ? cell.VisualX : cell.RenderX;
            float visualY = cell.VisualInitialized ? cell.VisualY : cell.RenderY;
            float visualSize = cell.VisualInitialized ? cell.VisualSize : cell.Size;
            float weight = Mathf.Max(1f, visualSize * visualSize);
            sumWeight += weight;
            weightedX += visualX * weight;
            weightedY += visualY * weight;
            largestSize = Mathf.Max(largestSize, visualSize);
            ownedCount++;
        }

        if (ownedCount == 0 || sumWeight <= 0f)
        {
            return false;
        }

        float centerX = weightedX / sumWeight;
        float centerY = weightedY / sumWeight;
        float aspect = _mainCamera != null ? Mathf.Max(1f, _mainCamera.aspect) : (16f / 9f);
        float requiredOrtho = CalcCameraOrthoSize(largestSize);

        foreach (CellView cell in _cells.Values)
        {
            if (cell.PlayerId != MyPlayerId)
            {
                continue;
            }

            float visualX = cell.VisualInitialized ? cell.VisualX : cell.RenderX;
            float visualY = cell.VisualInitialized ? cell.VisualY : cell.RenderY;
            float visualSize = cell.VisualInitialized ? cell.VisualSize : cell.Size;
            float radiusWorld = Mathf.Max(0.12f, visualSize * SCALE);
            float dxWorld = Mathf.Abs((visualX - centerX) * SCALE);
            float dyWorld = Mathf.Abs((visualY - centerY) * SCALE);
            float orthoForY = dyWorld + radiusWorld + CAMERA_EDGE_MARGIN;
            float orthoForX = (dxWorld + radiusWorld + CAMERA_EDGE_MARGIN) / aspect;
            requiredOrtho = Mathf.Max(requiredOrtho, orthoForY, orthoForX);
        }

        targetPos = new Vector3(centerX * SCALE, centerY * SCALE, 0f);
        targetOrtho = Mathf.Clamp(requiredOrtho, CAMERA_ORTHO_MIN, CAMERA_ORTHO_MAX);
        return true;
    }

    private static void SetLayerRecursively(GameObject obj, int layer)
    {
        if (obj == null) return;
        obj.layer = layer;
        foreach (Transform child in obj.transform)
        {
            if (child != null)
            {
                SetLayerRecursively(child.gameObject, layer);
            }
        }
    }

    private void RefreshFoodVisuals()
    {
        if (_foods.Count == 0)
        {
            return;
        }

        if (!TryGetVisibleFoodBounds(out float minX, out float maxX, out float minY, out float maxY))
        {
            return;
        }

        _foodIdsToRecycle.Clear();
        foreach (FoodView food in _foods.Values)
        {
            bool isVisible = food.X >= minX && food.X <= maxX && food.Y >= minY && food.Y <= maxY;
            if (isVisible)
            {
                CreateOrUpdateFoodVisual(food);
            }
            else if (food.Entity != null)
            {
                _foodIdsToRecycle.Add(food.Id);
            }
        }

        foreach (int foodId in _foodIdsToRecycle)
        {
            if (_foods.TryGetValue(foodId, out FoodView food))
            {
                ReleaseFoodVisual(food);
            }
        }
    }

    private bool TryGetVisibleFoodBounds(out float minX, out float maxX, out float minY, out float maxY)
    {
        minX = 0f;
        maxX = 0f;
        minY = 0f;
        maxY = 0f;

        EnsureMainCamera();
        if (_mainCamera == null)
        {
            return false;
        }

        float centerX = _mainCamera.transform.position.x / SCALE;
        float centerY = _mainCamera.transform.position.y / SCALE;
        float halfHeight = _mainCamera.orthographicSize / SCALE;
        float halfWidth = halfHeight * Mathf.Max(0.1f, _mainCamera.aspect);
        float margin = Mathf.Max(FOOD_VISUAL_MIN_MARGIN_MAP, halfHeight * FOOD_VISUAL_MARGIN_FACTOR);

        minX = centerX - halfWidth - margin;
        maxX = centerX + halfWidth + margin;
        minY = centerY - halfHeight - margin;
        maxY = centerY + halfHeight + margin;
        return true;
    }

    private FoodEntity AcquireFoodVisual()
    {
        while (_foodEntityPool.Count > 0)
        {
            FoodEntity pooled = _foodEntityPool.Pop();
            if (pooled == null)
            {
                continue;
            }

            pooled.gameObject.SetActive(true);
            if (_foodVisualRoot != null)
            {
                pooled.transform.SetParent(_foodVisualRoot, false);
            }
            return pooled;
        }

        return CreateFoodVisualObject();
    }

    private FoodEntity CreateFoodVisualObject()
    {
        GameObject obj = new GameObject("Food");
        if (_foodVisualRoot != null)
        {
            obj.transform.SetParent(_foodVisualRoot, false);
        }
        SetLayerRecursively(obj, RUNTIME_LAYER);
        return obj.AddComponent<FoodEntity>();
    }

    private void ReleaseFoodVisual(FoodView food)
    {
        if (food == null || food.Entity == null)
        {
            return;
        }

        FoodEntity entity = food.Entity;
        food.Entity = null;
        if (entity == null)
        {
            return;
        }

        if (_foodVisualRoot != null)
        {
            entity.transform.SetParent(_foodVisualRoot, false);
        }
        entity.gameObject.SetActive(false);
        _foodEntityPool.Push(entity);
    }

    private void PrewarmFoodEntityPool(int count)
    {
        for (int i = 0; i < count; i++)
        {
            FoodEntity entity = CreateFoodVisualObject();
            entity.gameObject.SetActive(false);
            _foodEntityPool.Push(entity);
        }
    }

    private static Material GetLineMaterial()
    {
        if (_cachedLineMaterial == null)
        {
            Shader shader = Shader.Find("Sprites/Default");
            if (shader != null)
            {
                _cachedLineMaterial = new Material(shader);
            }
        }
        return _cachedLineMaterial;
    }

    public BallEntity GetMyBall()
    {
        if (MyPlayerId == 0)
        {
            return null;
        }

        BallEntity best = null;
        float maxSize = -1f;
        foreach (CellView cell in _cells.Values)
        {
            if (cell.PlayerId != MyPlayerId || cell.Entity == null)
            {
                continue;
            }

            if (cell.Size > maxSize)
            {
                maxSize = cell.Size;
                best = cell.Entity;
            }
        }

        return best;
    }

    private float CalcCameraOrthoSize(float ballSize)
    {
        float size01 = Mathf.Clamp01((ballSize - 2f) / 30f);
        return Mathf.Lerp(CAMERA_ORTHO_MIN, CAMERA_ORTHO_MAX, size01);
    }
}
