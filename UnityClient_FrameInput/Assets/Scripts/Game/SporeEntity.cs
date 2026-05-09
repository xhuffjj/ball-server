using UnityEngine;

/// <summary>
/// 孢子实体 - 用于表现吐出的可移动孢子。
/// </summary>
public class SporeEntity : MonoBehaviour
{
    private const int SPORE_SPRITE_RES = 96;
    private const float GLOW_SCALE = 1.8f;

    public int SporeId { get; private set; }

    private SpriteRenderer _sr;
    private SpriteRenderer _glowSr;
    private static Sprite _cachedSprite;
    private static Sprite _cachedSoftSprite;
    private float _baseScale = 1f;
    private float _pulseSeed = 0f;

    public void Init(int sporeId, float x, float y)
    {
        SporeId = sporeId;
        _baseScale = GameManager.SCALE * 0.55f;
        _pulseSeed = Random.Range(0f, Mathf.PI * 2f);
        transform.localScale = new Vector3(_baseScale, _baseScale, 1f);

        _sr = gameObject.AddComponent<SpriteRenderer>();
        _sr.sprite = GetSporeSprite();
        _sr.sortingOrder = 4;
        _sr.color = new Color(0.94f, 0.98f, 0.68f, 1f);

        GameObject glowObj = new GameObject("Glow");
        glowObj.transform.SetParent(transform);
        glowObj.transform.localPosition = Vector3.zero;
        glowObj.layer = gameObject.layer;
        _glowSr = glowObj.AddComponent<SpriteRenderer>();
        _glowSr.sprite = GetSoftSprite();
        _glowSr.sortingOrder = 3;
        _glowSr.color = new Color(0.94f, 0.95f, 0.42f, 0.42f);
        _glowSr.transform.localScale = new Vector3(GLOW_SCALE, GLOW_SCALE, 1f);

        SetWorldPosition(x, y);
    }

    public void SetWorldPosition(float x, float y)
    {
        transform.position = new Vector3(x * GameManager.SCALE, y * GameManager.SCALE, 0f);
    }

    void Update()
    {
        float pulse = 1f + Mathf.Sin(Time.time * 7.2f + _pulseSeed) * 0.08f;
        transform.localScale = new Vector3(_baseScale * pulse, _baseScale * pulse, 1f);

        if (_glowSr != null)
        {
            float glowPulse = 1f + Mathf.Sin(Time.time * 6.1f + _pulseSeed * 0.7f) * 0.1f;
            float glowScale = GLOW_SCALE * glowPulse;
            _glowSr.transform.localScale = new Vector3(glowScale, glowScale, 1f);
        }
    }

    private static Sprite GetSporeSprite()
    {
        if (_cachedSprite == null)
        {
            _cachedSprite = CreateCircleSprite(SPORE_SPRITE_RES);
        }
        return _cachedSprite;
    }

    private static Sprite GetSoftSprite()
    {
        if (_cachedSoftSprite == null)
        {
            _cachedSoftSprite = CreateSoftCircleSprite(SPORE_SPRITE_RES);
        }
        return _cachedSoftSprite;
    }

    private static Sprite CreateCircleSprite(int resolution)
    {
        Texture2D tex = new Texture2D(resolution, resolution, TextureFormat.RGBA32, false);
        tex.filterMode = FilterMode.Bilinear;
        tex.wrapMode = TextureWrapMode.Clamp;

        float center = resolution * 0.5f;
        float radius = resolution * 0.5f - 1f;
        for (int y = 0; y < resolution; y++)
        {
            for (int x = 0; x < resolution; x++)
            {
                float dx = x - center + 0.5f;
                float dy = y - center + 0.5f;
                float dist = Mathf.Sqrt(dx * dx + dy * dy);
                if (dist <= radius - 0.7f)
                {
                    tex.SetPixel(x, y, Color.white);
                }
                else if (dist < radius + 0.7f)
                {
                    float alpha = Mathf.Clamp01((radius + 0.7f - dist) / 1.4f);
                    tex.SetPixel(x, y, new Color(1f, 1f, 1f, alpha));
                }
                else
                {
                    tex.SetPixel(x, y, Color.clear);
                }
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
                float dist01 = Mathf.Clamp01(Mathf.Sqrt(dx * dx + dy * dy) / radius);
                float alpha = Mathf.Pow(1f - dist01, 2.1f);
                tex.SetPixel(x, y, new Color(1f, 1f, 1f, alpha));
            }
        }

        tex.Apply();
        return Sprite.Create(tex, new Rect(0, 0, resolution, resolution), new Vector2(0.5f, 0.5f), resolution);
    }
}
