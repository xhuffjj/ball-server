using UnityEngine;

/// <summary>
/// 场景环境粒子：缓慢漂移 + 明暗闪烁
/// </summary>
public class AmbientParticle : MonoBehaviour
{
    public Vector2 MinBound;
    public Vector2 MaxBound;
    public Vector2 Velocity;
    public float TwinkleSpeed = 1.4f;
    public float AlphaMin = 0.05f;
    public float AlphaMax = 0.25f;

    private SpriteRenderer _sr;
    private float _phase;
    private Vector3 _baseScale;

    void Awake()
    {
        _sr = GetComponent<SpriteRenderer>();
        _phase = Random.Range(0f, Mathf.PI * 2f);
        _baseScale = transform.localScale;
    }

    void Update()
    {
        Vector3 p = transform.position;
        p.x += Velocity.x * Time.deltaTime;
        p.y += Velocity.y * Time.deltaTime;

        float width = MaxBound.x - MinBound.x;
        float height = MaxBound.y - MinBound.y;
        if (width > 0f)
        {
            if (p.x < MinBound.x) p.x += width;
            else if (p.x > MaxBound.x) p.x -= width;
        }
        if (height > 0f)
        {
            if (p.y < MinBound.y) p.y += height;
            else if (p.y > MaxBound.y) p.y -= height;
        }
        transform.position = p;

        float twinkle = (Mathf.Sin(Time.time * TwinkleSpeed + _phase) + 1f) * 0.5f;
        float alpha = Mathf.Lerp(AlphaMin, AlphaMax, twinkle);
        float scale = Mathf.Lerp(0.9f, 1.12f, twinkle);

        if (_sr != null)
        {
            Color c = _sr.color;
            c.a = alpha;
            _sr.color = c;
        }
        transform.localScale = _baseScale * scale;
    }
}

