using UnityEngine;

/// <summary>
/// 球球实体 - 可视化表现
/// 使用程序化生成的圆形 Sprite
/// 支持平滑位置插值和大小缩放
/// </summary>
public class BallEntity : MonoBehaviour
{
    private const int BALL_SPRITE_RES = 256;
    private const float GLOW_BASE_SCALE = 1.30f;
    private const float GLOW_PULSE_AMPLITUDE = 0.06f;
    public int CellId { get; private set; }
    public int PlayerId { get; private set; }
    public float BallSize { get; private set; }
    public bool IsMyBall => _isMyBall;

    private bool _isMyBall = false;
    private int _protectedTimer = 0;
    private SpriteRenderer _sr;
    private SpriteRenderer _borderSr;
    private SpriteRenderer _glowSr;
    private SpriteRenderer _shadowSr;
    private SpriteRenderer _highlightSr;
    private TextMesh _nameText;
    private MeshRenderer _nameRenderer;
    private static Sprite _cachedCircleSprite;
    private static Sprite _cachedSoftCircleSprite;
    private static Sprite _cachedHighlightSprite;
    private static bool _externalOrbLoadAttempted;
    private static Sprite[] _externalOrbSprites;
    private float _targetDiameter;
    private float _displayDiameter;
    private float _sizePop = 1f;
    private bool _sizeInited = false;
    private float _pulseSeed;
    private float _highlightBaseScale = 0.46f;
    private bool _usingExternalMainSprite;
    private bool _lowDetailMode;
    private const float SIZE_EPSILON = 0.0001f;

    private static readonly string[] ExternalOrbPaths = new string[]
    {
        "Art/Game/Orbs/Orb_01.png",
        "Art/Game/Orbs/Orb_02.png",
        "Art/Game/Orbs/Orb_03.png",
        "Art/Game/Orbs/Orb_04.png",
        "Art/Game/Orbs/Orb_05.png",
        "Art/Game/Orbs/Orb_06.png",
        "Art/Game/Orbs/Orb_07.png",
        "Art/Game/Orbs/Orb_08.png",
        "Art/Game/Orbs/Orb_09.png",
        "Art/Game/Orbs/Orb_10.png",
        "Art/Game/Orbs/Orb_11.png",
        "Art/Game/Orbs/Orb_12.png",
        "Art/Game/Orbs/Orb_13.png",
        "Art/Game/Orbs/Orb_14.png",
        "Art/Game/Orbs/Orb_15.png",
        "Art/Game/Orbs/Orb_16.png",
        "Art/Game/Orbs/Orb_17.png",
        "Art/Game/Orbs/Orb_18.png",
    };

    // 预定义的玩家颜色
    private static readonly Color[] PlayerColors = new Color[]
    {
        new Color(0.2f, 0.7f, 1.0f),   // 蓝色
        new Color(1.0f, 0.4f, 0.4f),   // 红色
        new Color(0.4f, 1.0f, 0.4f),   // 绿色
        new Color(1.0f, 0.8f, 0.2f),   // 黄色
        new Color(0.8f, 0.4f, 1.0f),   // 紫色
        new Color(1.0f, 0.6f, 0.2f),   // 橙色
        new Color(0.2f, 1.0f, 0.8f),   // 青色
        new Color(1.0f, 0.4f, 0.8f),   // 粉色
    };

    /// <summary>
    /// 初始化球球
    /// </summary>
    public void Init(int cellId, int playerId, float x, float y, float size, bool isMyBall)
    {
        CellId = cellId;
        PlayerId = playerId;
        BallSize = size;
        _isMyBall = isMyBall;

        // 设置初始位置
        transform.position = new Vector3(x * GameManager.SCALE, y * GameManager.SCALE, 0);

        // 创建圆形 Sprite
        _sr = gameObject.AddComponent<SpriteRenderer>();
        _sr.sprite = GetCircleSprite(playerId, out _usingExternalMainSprite);
        _sr.sortingOrder = 5;

        // 边框（稍大一点的暗色圆）
        GameObject borderObj = new GameObject("Border");
        borderObj.transform.SetParent(transform);
        borderObj.transform.localPosition = Vector3.zero;
        borderObj.layer = gameObject.layer;
        _borderSr = borderObj.AddComponent<SpriteRenderer>();
        if (_usingExternalMainSprite)
        {
            _borderSr.sprite = GetSoftCircleSprite();
        }
        else
        {
            bool _;
            _borderSr.sprite = GetCircleSprite(playerId, out _);
        }
        _borderSr.sortingOrder = 4;

        // 柔光层（在球后方）
        GameObject glowObj = new GameObject("Glow");
        glowObj.transform.SetParent(transform);
        glowObj.transform.localPosition = Vector3.zero;
        glowObj.layer = gameObject.layer;
        _glowSr = glowObj.AddComponent<SpriteRenderer>();
        _glowSr.sprite = GetSoftCircleSprite();
        _glowSr.sortingOrder = 3;

        // 投影层（偏移一点点，增强体积感）
        GameObject shadowObj = new GameObject("Shadow");
        shadowObj.transform.SetParent(transform);
        shadowObj.transform.localPosition = new Vector3(0.07f, -0.07f, 0f);
        shadowObj.layer = gameObject.layer;
        _shadowSr = shadowObj.AddComponent<SpriteRenderer>();
        _shadowSr.sprite = GetSoftCircleSprite();
        _shadowSr.sortingOrder = 2;
        _shadowSr.color = new Color(0f, 0f, 0f, 0.22f);

        // 名称标签
        GameObject textObj = new GameObject("Name");
        textObj.transform.SetParent(transform);
        textObj.transform.localPosition = Vector3.zero;
        textObj.layer = gameObject.layer;
        _nameText = textObj.AddComponent<TextMesh>();
        _nameText.text = _isMyBall ? $"我({playerId})" : playerId.ToString();
        _nameText.fontSize = 36;
        _nameText.characterSize = 0.15f;
        _nameText.anchor = TextAnchor.MiddleCenter;
        _nameText.alignment = TextAlignment.Center;
        _nameText.color = Color.white;
        // 确保文字在球上方
        var tr = textObj.GetComponent<MeshRenderer>();
        if (tr == null)
            tr = textObj.AddComponent<MeshRenderer>();
        tr.sortingOrder = 10;
        _nameRenderer = tr;

        // 高光层（在球前方）
        GameObject highlightObj = new GameObject("Highlight");
        highlightObj.transform.SetParent(transform);
        highlightObj.transform.localPosition = new Vector3(-0.16f, 0.16f, 0f);
        highlightObj.layer = gameObject.layer;
        _highlightSr = highlightObj.AddComponent<SpriteRenderer>();
        _highlightSr.sprite = GetHighlightSprite();
        _highlightSr.sortingOrder = 6;
        _highlightBaseScale = _usingExternalMainSprite ? 0.30f : 0.46f;
        _highlightSr.transform.localScale = new Vector3(_highlightBaseScale, _highlightBaseScale, 1f);

        _pulseSeed = Random.Range(0f, Mathf.PI * 2f);

        RefreshVisualPalette();
        ApplyRenderSize(size);
        ApplyDetailMode();

        // 初次创建时如果就是自己的球，需要立即激活控制器
        if (_isMyBall)
        {
            SetAsMyBall();
        }
    }

    /// <summary>
    /// 标记为自己的球
    /// </summary>
    public void SetAsMyBall()
    {
        _isMyBall = true;
        if (_nameText != null)
            _nameText.text = $"我({PlayerId})";
        RefreshVisualPalette();
        ApplyDetailMode();

    }

    public void SetProtectedTimer(int protectedTimer)
    {
        int nextTimer = Mathf.Max(0, protectedTimer);
        if (_protectedTimer == nextTimer)
        {
            return;
        }

        _protectedTimer = nextTimer;
        RefreshVisualPalette();
    }

    public void SetLowDetailMode(bool lowDetailMode)
    {
        if (_lowDetailMode == lowDetailMode)
        {
            return;
        }

        _lowDetailMode = lowDetailMode;
        ApplyDetailMode();
        ApplyVisualScale();
    }

    /// <summary>
    /// 应用当前渲染态
    /// </summary>
    public void ApplyRenderState(float x, float y, float size)
    {
        transform.position = new Vector3(x * GameManager.SCALE, y * GameManager.SCALE, 0f);
        ApplyRenderSize(size);
    }

    /// <summary>
    /// 兼容旧接口，直接更新当前位置
    /// </summary>
    public void SetTargetPosition(float x, float y)
    {
        transform.position = new Vector3(x * GameManager.SCALE, y * GameManager.SCALE, 0f);
    }

    /// <summary>
    /// 本地输入速度（用于自己的球预测）
    /// </summary>
    public void SetLocalControlVelocity(float vx, float vy)
    {
        // 回放模式下由 GameManager 统一驱动渲染态，这里保留接口避免调用方改动过大。
    }

    /// <summary>
    /// 更新球大小
    /// </summary>
    public void UpdateSize(float newSize)
    {
        ApplyRenderSize(newSize);
    }

    private void ApplyRenderSize(float newSize)
    {
        if (_sizeInited && Mathf.Abs(BallSize - newSize) <= SIZE_EPSILON)
        {
            return;
        }

        BallSize = newSize;
        // Sprite 在 scale=1 时直径约为 1 个世界单位，因此需要把服务端半径转换成直径
        float diameter = Mathf.Max(0.2f, newSize * GameManager.SCALE * 2f);
        if (!_sizeInited)
        {
            _targetDiameter = diameter;
            _displayDiameter = diameter;
            _sizePop = 1f;
            _sizeInited = true;
            ApplyVisualScale();
            return;
        }
        _targetDiameter = diameter;
        _displayDiameter = diameter;
        _sizePop = 1f;
        ApplyVisualScale();
    }

    void Update()
    {
        UpdateScaleAnimation();
    }

    private void UpdateScaleAnimation()
    {
        if (!_sizeInited) return;
        ApplyVisualScale();
    }

    private void ApplyVisualScale()
    {
        float finalDiameter = _displayDiameter * _sizePop;
        transform.localScale = new Vector3(finalDiameter, finalDiameter, 1f);

        // 边框稍大
        if (_borderSr != null)
            _borderSr.transform.localScale = new Vector3(1.1f, 1.1f, 1f);
        if (_shadowSr != null)
            _shadowSr.transform.localScale = new Vector3(1.10f, 1.10f, 1f);
        if (_lowDetailMode)
        {
            if (_glowSr != null)
                _glowSr.transform.localScale = Vector3.one * GLOW_BASE_SCALE;
            if (_highlightSr != null)
                _highlightSr.transform.localScale = new Vector3(_highlightBaseScale, _highlightBaseScale, 1f);
            return;
        }
        if (_glowSr != null)
        {
            float pulse = 1f + Mathf.Sin(Time.time * 4.2f + _pulseSeed) * GLOW_PULSE_AMPLITUDE;
            float glowScale = GLOW_BASE_SCALE * pulse;
            _glowSr.transform.localScale = new Vector3(glowScale, glowScale, 1f);
        }
        if (_highlightSr != null)
        {
            float hPulse = 1f + Mathf.Sin(Time.time * 3.4f + _pulseSeed * 0.6f) * 0.07f;
            float hScale = _highlightBaseScale * hPulse;
            _highlightSr.transform.localScale = new Vector3(hScale, hScale, 1f);
        }
    }

    private void ApplyDetailMode()
    {
        if (_glowSr != null)
            _glowSr.enabled = !_lowDetailMode;
        if (_shadowSr != null)
            _shadowSr.enabled = !_lowDetailMode;
        if (_highlightSr != null)
            _highlightSr.enabled = !_lowDetailMode;
        if (_nameRenderer != null)
            _nameRenderer.enabled = !_lowDetailMode;

        enabled = !_lowDetailMode;
    }

    private void RefreshVisualPalette()
    {
        Color baseTint = _isMyBall
            ? new Color(0.3f, 0.9f, 0.5f)
            : PlayerColors[Mathf.Abs(PlayerId) % PlayerColors.Length];

        if (_protectedTimer > 0)
        {
            if (_sr != null)
                _sr.color = _usingExternalMainSprite
                    ? new Color(1f, 0.95f, 0.70f, 1f)
                    : new Color(1.0f, 0.88f, 0.30f, 1f);
            if (_borderSr != null)
                _borderSr.color = _usingExternalMainSprite
                    ? new Color(0.40f, 0.24f, 0.02f, 0.72f)
                    : new Color(0.70f, 0.42f, 0.08f, 1f);
            if (_glowSr != null)
                _glowSr.color = new Color(1.0f, 0.86f, 0.22f, 0.48f);
            if (_highlightSr != null)
                _highlightSr.color = new Color(1f, 0.98f, 0.80f, 0.42f);
            return;
        }

        if (_sr != null)
            _sr.color = _usingExternalMainSprite
                ? (_isMyBall ? new Color(0.86f, 1f, 0.90f, 1f) : Color.white)
                : baseTint;
        if (_borderSr != null)
            _borderSr.color = _usingExternalMainSprite
                ? (_isMyBall ? new Color(0.02f, 0.06f, 0.04f, 0.56f) : new Color(0f, 0f, 0f, 0.42f))
                : (_isMyBall ? new Color(0.15f, 0.45f, 0.25f) : baseTint * 0.5f);
        if (_glowSr != null)
            _glowSr.color = _usingExternalMainSprite
                ? (_isMyBall ? new Color(0.44f, 1f, 0.74f, 0.34f) : new Color(1f, 1f, 1f, 0.30f))
                : (_isMyBall ? new Color(0.3f, 0.95f, 0.55f, 0.34f) : new Color(baseTint.r, baseTint.g, baseTint.b, 0.30f));
        if (_highlightSr != null)
            _highlightSr.color = _usingExternalMainSprite
                ? new Color(1f, 1f, 1f, 0.30f)
                : new Color(1f, 1f, 1f, 0.24f);
    }

    /// <summary>
    /// 程序化创建圆形 Sprite（无需外部资源）
    /// </summary>
    private static Sprite GetCircleSprite(int playerId, out bool isExternal)
    {
        EnsureExternalOrbSprites();
        if (_externalOrbSprites != null && _externalOrbSprites.Length > 0)
        {
            int startIndex = Mathf.Abs(playerId) % _externalOrbSprites.Length;
            for (int i = 0; i < _externalOrbSprites.Length; i++)
            {
                int idx = (startIndex + i) % _externalOrbSprites.Length;
                if (_externalOrbSprites[idx] != null)
                {
                    isExternal = true;
                    return _externalOrbSprites[idx];
                }
            }
        }

        isExternal = false;
        if (_cachedCircleSprite == null)
        {
            _cachedCircleSprite = CreateCircleSprite(BALL_SPRITE_RES);
        }
        return _cachedCircleSprite;
    }

    private static void EnsureExternalOrbSprites()
    {
        if (_externalOrbLoadAttempted) return;
        _externalOrbLoadAttempted = true;

        _externalOrbSprites = new Sprite[ExternalOrbPaths.Length];
        int loadedCount = 0;
        for (int i = 0; i < ExternalOrbPaths.Length; i++)
        {
            _externalOrbSprites[i] = ExternalArtLoader.LoadSprite(ExternalOrbPaths[i]);
            if (_externalOrbSprites[i] != null)
                loadedCount++;
        }
        if (loadedCount == 0)
        {
            _externalOrbSprites = null;
        }
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
                _cachedSoftCircleSprite = CreateSoftCircleSprite(BALL_SPRITE_RES);
            }
        }
        return _cachedSoftCircleSprite;
    }

    private static Sprite GetHighlightSprite()
    {
        if (_cachedHighlightSprite == null)
        {
            _cachedHighlightSprite = ExternalArtLoader.LoadSprite("Art/Game/Particles/star_01.png");
            if (_cachedHighlightSprite == null)
            {
                _cachedHighlightSprite = GetSoftCircleSprite();
            }
        }
        return _cachedHighlightSprite;
    }

    private static Sprite CreateCircleSprite(int resolution)
    {
        Texture2D tex = new Texture2D(resolution, resolution, TextureFormat.RGBA32, false);
        tex.filterMode = FilterMode.Bilinear;
        tex.wrapMode = TextureWrapMode.Clamp;

        float center = resolution / 2f;
        float radius = resolution * 0.5f - 1.5f;

        for (int y = 0; y < resolution; y++)
        {
            for (int x = 0; x < resolution; x++)
            {
                float dx = x - center + 0.5f;
                float dy = y - center + 0.5f;
                float dist = Mathf.Sqrt(dx * dx + dy * dy);

                if (dist <= radius - 0.8f)
                {
                    tex.SetPixel(x, y, Color.white);
                }
                else if (dist < radius + 0.8f)
                {
                    float alpha = Mathf.Clamp01((radius + 0.8f - dist) / 1.6f);
                    tex.SetPixel(x, y, new Color(1f, 1f, 1f, alpha));
                }
                else
                {
                    tex.SetPixel(x, y, Color.clear);
                }
            }
        }

        tex.Apply();
        return Sprite.Create(tex, new Rect(0, 0, resolution, resolution),
            new Vector2(0.5f, 0.5f), resolution);
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
        return Sprite.Create(
            tex,
            new Rect(0, 0, resolution, resolution),
            new Vector2(0.5f, 0.5f),
            resolution);
    }
}
