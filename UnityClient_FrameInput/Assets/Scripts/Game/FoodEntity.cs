using UnityEngine;

/// <summary>
/// 食物实体 - 小圆点
/// 随机颜色，出现时有缩放动画
/// </summary>
public class FoodEntity : MonoBehaviour
{
    private const int FOOD_SPRITE_RES = 128;
    private const float GLOW_SCALE = 2.3f;
    public int FoodId { get; private set; }

    private SpriteRenderer _sr;
    private SpriteRenderer _glowSr;
    private SpriteRenderer _sparkSr;
    private static Sprite _cachedFoodSprite;
    private static Sprite _cachedSoftSprite;
    private static Sprite _cachedSparkSprite;
    private static bool _externalFoodLoadAttempted;
    private static Sprite[] _externalFoodSprites;
    private bool _usingExternalFoodSprite;

    // 食物颜色集
    private static readonly Color[] FoodColors = new Color[]
    {
        new Color(1.0f, 0.3f, 0.3f),
        new Color(0.3f, 1.0f, 0.3f),
        new Color(0.3f, 0.5f, 1.0f),
        new Color(1.0f, 1.0f, 0.3f),
        new Color(1.0f, 0.5f, 0.0f),
        new Color(0.8f, 0.3f, 1.0f),
        new Color(0.3f, 1.0f, 1.0f),
        new Color(1.0f, 0.6f, 0.8f),
    };

    // 缩放动画
    private float _animTime = 0;
    private bool _animating = true;
    private float _baseScale;
    private Vector3 _basePos;
    private float _pulseSeed;
    private float _sparkBaseScale = 0.35f;
    private bool _visualsReady = false;

    private static readonly string[] ExternalFoodPaths = new string[]
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
    };

    public void Init(int id, float x, float y)
    {
        Bind(id, x, y);
    }

    public void Bind(int id, float x, float y)
    {
        EnsureVisuals();
        if (!_visualsReady || FoodId != id)
        {
            ApplyAppearance(id);
            _visualsReady = true;
        }
        SetWorldPosition(x, y);
    }

    private void EnsureVisuals()
    {
        if (_sr == null)
        {
            _sr = gameObject.GetComponent<SpriteRenderer>();
            if (_sr == null)
            {
                _sr = gameObject.AddComponent<SpriteRenderer>();
            }
        }

        if (_glowSr == null)
        {
            Transform glowTransform = transform.Find("Glow");
            GameObject glowObj = glowTransform != null ? glowTransform.gameObject : new GameObject("Glow");
            if (glowTransform == null)
            {
                glowObj.transform.SetParent(transform, false);
            }
            glowObj.layer = gameObject.layer;
            _glowSr = glowObj.GetComponent<SpriteRenderer>();
            if (_glowSr == null)
            {
                _glowSr = glowObj.AddComponent<SpriteRenderer>();
            }
        }

        if (_sparkSr == null)
        {
            Transform sparkTransform = transform.Find("Spark");
            GameObject sparkObj = sparkTransform != null ? sparkTransform.gameObject : new GameObject("Spark");
            if (sparkTransform == null)
            {
                sparkObj.transform.SetParent(transform, false);
            }
            sparkObj.layer = gameObject.layer;
            _sparkSr = sparkObj.GetComponent<SpriteRenderer>();
            if (_sparkSr == null)
            {
                _sparkSr = sparkObj.AddComponent<SpriteRenderer>();
            }
        }
    }

    private void ApplyAppearance(int id)
    {
        FoodId = id;
        gameObject.name = $"Food_{id}";

        _sr.sprite = GetFoodSprite(id, out _usingExternalFoodSprite);
        _sr.sortingOrder = 2;

        Color mainColor = FoodColors[Mathf.Abs(id) % FoodColors.Length];
        _sr.color = _usingExternalFoodSprite ? Color.white : mainColor;
        _baseScale = GameManager.SCALE * (_usingExternalFoodSprite ? 0.34f : 0.4f);

        _glowSr.transform.localPosition = Vector3.zero;
        _glowSr.sprite = GetSoftSprite();
        _glowSr.sortingOrder = 1;
        _glowSr.color = _usingExternalFoodSprite
            ? new Color(1f, 0.90f, 0.70f, 0.38f)
            : new Color(mainColor.r, mainColor.g, mainColor.b, 0.38f);

        _sparkSr.transform.localPosition = new Vector3(-0.12f, 0.12f, 0f);
        _sparkSr.sprite = GetSparkSprite();
        _sparkSr.sortingOrder = 3;
        _sparkSr.color = new Color(1f, 1f, 1f, 0.60f);
        _sparkBaseScale = _usingExternalFoodSprite ? 0.26f : 0.35f;
        _sparkSr.transform.localScale = new Vector3(_sparkBaseScale, _sparkBaseScale, 1f);

        _animating = true;
        _animTime = 0f;
        _pulseSeed = Random.Range(0f, Mathf.PI * 2f);
        transform.localScale = Vector3.zero;
    }

    public void SetWorldPosition(float x, float y)
    {
        _basePos = new Vector3(x * GameManager.SCALE, y * GameManager.SCALE, 0f);
        transform.position = _basePos;
    }

    void Update()
    {
        float scale = _baseScale;
        if (_animating)
        {
            _animTime += Time.deltaTime * 5f;
            float t = Mathf.Min(_animTime, 1f);
            // 弹性缩放
            float eased = 1f + Mathf.Sin(t * Mathf.PI) * 0.3f; // 轻微弹跳
            if (t >= 1f)
            {
                eased = 1f;
                _animating = false;
            }
            scale = _baseScale * eased;
        }
        else
        {
            float pulse = 1f + Mathf.Sin(Time.time * 6f + _pulseSeed) * 0.10f;
            scale = _baseScale * pulse;
        }

        float bob = Mathf.Sin(Time.time * 2.5f + _pulseSeed) * 0.035f;
        transform.position = new Vector3(_basePos.x, _basePos.y + bob, 0f);
        transform.localScale = new Vector3(scale, scale, 1f);

        if (_glowSr != null)
        {
            float gp = 1f + Mathf.Sin(Time.time * 5f + _pulseSeed) * 0.10f;
            float gs = GLOW_SCALE * gp;
            _glowSr.transform.localScale = new Vector3(gs, gs, 1f);
        }
        if (_sparkSr != null)
        {
            float sp = 1f + Mathf.Sin(Time.time * 7f + _pulseSeed * 0.7f) * 0.18f;
            _sparkSr.transform.localScale = new Vector3(_sparkBaseScale * sp, _sparkBaseScale * sp, 1f);
            Color c = _sparkSr.color;
            c.a = 0.45f + Mathf.Sin(Time.time * 7f + _pulseSeed) * 0.18f;
            _sparkSr.color = c;
        }
    }

    /// <summary>
    /// 程序化创建食物 Sprite（小圆点）
    /// </summary>
    private static Sprite GetFoodSprite(int foodId, out bool isExternal)
    {
        EnsureExternalFoodSprites();
        if (_externalFoodSprites != null && _externalFoodSprites.Length > 0)
        {
            int startIndex = Mathf.Abs(foodId) % _externalFoodSprites.Length;
            for (int i = 0; i < _externalFoodSprites.Length; i++)
            {
                int idx = (startIndex + i) % _externalFoodSprites.Length;
                if (_externalFoodSprites[idx] != null)
                {
                    isExternal = true;
                    return _externalFoodSprites[idx];
                }
            }
        }

        isExternal = false;
        if (_cachedFoodSprite == null)
        {
            _cachedFoodSprite = CreateFoodSprite(FOOD_SPRITE_RES);
        }
        return _cachedFoodSprite;
    }

    private static void EnsureExternalFoodSprites()
    {
        if (_externalFoodLoadAttempted) return;
        _externalFoodLoadAttempted = true;

        _externalFoodSprites = new Sprite[ExternalFoodPaths.Length];
        int loadedCount = 0;
        for (int i = 0; i < ExternalFoodPaths.Length; i++)
        {
            _externalFoodSprites[i] = ExternalArtLoader.LoadSprite(ExternalFoodPaths[i]);
            if (_externalFoodSprites[i] != null)
                loadedCount++;
        }
        if (loadedCount == 0)
        {
            _externalFoodSprites = null;
        }
    }

    private static Sprite GetSoftSprite()
    {
        if (_cachedSoftSprite == null)
        {
            _cachedSoftSprite = ExternalArtLoader.LoadSprite("Art/Game/Particles/circle_04.png");
            if (_cachedSoftSprite == null)
            {
                _cachedSoftSprite = ExternalArtLoader.LoadSprite("Art/Game/Particles/light_01.png");
            }
            if (_cachedSoftSprite == null)
            {
                _cachedSoftSprite = CreateSoftSprite(FOOD_SPRITE_RES);
            }
        }
        return _cachedSoftSprite;
    }

    private static Sprite GetSparkSprite()
    {
        if (_cachedSparkSprite == null)
        {
            _cachedSparkSprite = ExternalArtLoader.LoadSprite("Art/Game/Particles/star_01.png");
            if (_cachedSparkSprite == null)
            {
                _cachedSparkSprite = GetSoftSprite();
            }
        }
        return _cachedSparkSprite;
    }

    private static Sprite CreateFoodSprite(int resolution)
    {
        Texture2D tex = new Texture2D(resolution, resolution, TextureFormat.RGBA32, false);
        tex.filterMode = FilterMode.Bilinear;
        tex.wrapMode = TextureWrapMode.Clamp;

        float center = resolution / 2f;
        float radius = resolution * 0.5f - 1.2f;

        for (int y = 0; y < resolution; y++)
        {
            for (int x = 0; x < resolution; x++)
            {
                float dx = x - center + 0.5f;
                float dy = y - center + 0.5f;
                float dist = Mathf.Sqrt(dx * dx + dy * dy);

                if (dist <= radius - 0.6f)
                {
                    tex.SetPixel(x, y, Color.white);
                }
                else if (dist < radius + 0.6f)
                {
                    float alpha = Mathf.Clamp01((radius + 0.6f - dist) / 1.2f);
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

    private static Sprite CreateSoftSprite(int resolution)
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
