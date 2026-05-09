using UnityEngine;

/// <summary>
/// IMGUI 通用美术主题：背景、卡片、按钮、输入框与分隔线
/// </summary>
public static class UIArtTheme
{
    private static bool _inited;
    private static bool _usingExternalTheme;
    private static Texture2D _whiteTex;
    private static Texture2D _screenTex;
    private static Texture2D _panelTex;
    private static Texture2D _insetTex;
    private static Texture2D _buttonTex;
    private static Texture2D _buttonHoverTex;
    private static Texture2D _buttonActiveTex;
    private static Texture2D _tabTex;
    private static Texture2D _tabActiveTex;
    private static Texture2D _inputTex;
    private static Texture2D _softGlowTex;

    public static Texture2D PanelTex { get { EnsureInit(); return _panelTex; } }
    public static Texture2D InsetTex { get { EnsureInit(); return _insetTex; } }
    public static Texture2D ButtonTex { get { EnsureInit(); return _buttonTex; } }
    public static Texture2D ButtonHoverTex { get { EnsureInit(); return _buttonHoverTex; } }
    public static Texture2D ButtonActiveTex { get { EnsureInit(); return _buttonActiveTex; } }
    public static Texture2D TabTex { get { EnsureInit(); return _tabTex; } }
    public static Texture2D TabActiveTex { get { EnsureInit(); return _tabActiveTex; } }
    public static Texture2D InputTex { get { EnsureInit(); return _inputTex; } }

    public static void EnsureInit()
    {
        if (_inited) return;

        _whiteTex = CreateSolidTexture(new Color(1f, 1f, 1f, 1f));
        int externalCount = 0;
        _screenTex = ExternalArtLoader.LoadTexture(
            "Art/Game/Background/bg_space_seamless.png",
            FilterMode.Bilinear,
            TextureWrapMode.Repeat);
        if (_screenTex != null) externalCount++;
        _panelTex = ExternalArtLoader.LoadTexture("Art/UI/panel_glass.png");
        if (_panelTex != null) externalCount++;
        _insetTex = ExternalArtLoader.LoadTexture("Art/UI/panel_rectangle.png");
        if (_insetTex != null) externalCount++;
        _buttonTex = ExternalArtLoader.LoadTexture("Art/UI/button_normal.png");
        if (_buttonTex != null) externalCount++;
        _buttonHoverTex = ExternalArtLoader.LoadTexture("Art/UI/button_hover.png");
        if (_buttonHoverTex != null) externalCount++;
        _buttonActiveTex = ExternalArtLoader.LoadTexture("Art/UI/button_active.png");
        if (_buttonActiveTex != null) externalCount++;
        _tabTex = ExternalArtLoader.LoadTexture("Art/UI/tab.png");
        if (_tabTex != null) externalCount++;
        _tabActiveTex = ExternalArtLoader.LoadTexture("Art/UI/tab_active.png");
        if (_tabActiveTex != null) externalCount++;
        _inputTex = ExternalArtLoader.LoadTexture("Art/UI/input.png");
        if (_inputTex != null) externalCount++;

        _usingExternalTheme = externalCount >= 6;

        if (_screenTex == null)
        {
            _screenTex = CreateVerticalGradientTexture(
                256, 256,
                new Color(0.08f, 0.16f, 0.30f, 1f),
                new Color(0.02f, 0.04f, 0.10f, 1f),
                0.06f);
        }
        if (_panelTex == null)
        {
            _panelTex = CreateVerticalGradientTexture(
                128, 128,
                new Color(0.10f, 0.17f, 0.30f, 0.95f),
                new Color(0.05f, 0.09f, 0.17f, 0.95f),
                0.04f);
        }
        if (_insetTex == null)
        {
            _insetTex = CreateVerticalGradientTexture(
                64, 64,
                new Color(0.06f, 0.10f, 0.17f, 0.94f),
                new Color(0.03f, 0.06f, 0.12f, 0.94f),
                0.03f);
        }
        if (_buttonTex == null)
        {
            _buttonTex = CreateVerticalGradientTexture(
                64, 64,
                new Color(0.17f, 0.38f, 0.64f, 1f),
                new Color(0.10f, 0.23f, 0.45f, 1f),
                0.03f);
        }
        if (_buttonHoverTex == null)
        {
            _buttonHoverTex = CreateVerticalGradientTexture(
                64, 64,
                new Color(0.22f, 0.48f, 0.79f, 1f),
                new Color(0.13f, 0.31f, 0.59f, 1f),
                0.03f);
        }
        if (_buttonActiveTex == null)
        {
            _buttonActiveTex = CreateVerticalGradientTexture(
                64, 64,
                new Color(0.15f, 0.31f, 0.53f, 1f),
                new Color(0.10f, 0.21f, 0.41f, 1f),
                0.03f);
        }
        if (_tabTex == null)
        {
            _tabTex = CreateVerticalGradientTexture(
                64, 64,
                new Color(0.16f, 0.24f, 0.37f, 1f),
                new Color(0.10f, 0.16f, 0.26f, 1f),
                0.02f);
        }
        if (_tabActiveTex == null)
        {
            _tabActiveTex = CreateVerticalGradientTexture(
                64, 64,
                new Color(0.13f, 0.43f, 0.62f, 1f),
                new Color(0.08f, 0.29f, 0.46f, 1f),
                0.02f);
        }
        if (_inputTex == null)
        {
            _inputTex = CreateVerticalGradientTexture(
                32, 32,
                new Color(0.08f, 0.13f, 0.22f, 0.97f),
                new Color(0.05f, 0.08f, 0.15f, 0.97f),
                0.01f);
        }
        _softGlowTex = CreateSoftCircleTexture(128);

        _inited = true;
    }

    public static void DrawScreenBackdrop()
    {
        EnsureInit();
        GUI.DrawTexture(new Rect(0, 0, Screen.width, Screen.height), _screenTex, ScaleMode.StretchToFill);
        if (_usingExternalTheme)
        {
            DrawRect(new Rect(0, 0, Screen.width, Screen.height), new Color(0.01f, 0.05f, 0.12f, 0.48f));
        }

        float t = Time.realtimeSinceStartup;
        DrawGlow(
            new Vector2(Screen.width * 0.18f + Mathf.Sin(t * 0.35f) * 26f, Screen.height * 0.22f),
            Screen.height * 0.62f,
            new Color(0.22f, 0.75f, 1f, 0.12f));
        DrawGlow(
            new Vector2(Screen.width * 0.82f + Mathf.Cos(t * 0.27f) * 18f, Screen.height * 0.30f),
            Screen.height * 0.48f,
            new Color(0.14f, 0.92f, 0.86f, 0.09f));
        DrawGlow(
            new Vector2(Screen.width * 0.52f, Screen.height * 0.85f + Mathf.Sin(t * 0.22f) * 16f),
            Screen.height * 0.70f,
            new Color(0.35f, 0.40f, 1f, 0.08f));
    }

    public static void DrawGlassPanel(Rect rect, float glowAlpha = 0.22f)
    {
        EnsureInit();

        Rect glowRect = new Rect(rect.x - 26f, rect.y - 26f, rect.width + 52f, rect.height + 52f);
        Color old = GUI.color;
        GUI.color = new Color(0.35f, 0.85f, 1f, glowAlpha);
        GUI.DrawTexture(glowRect, _softGlowTex, ScaleMode.StretchToFill, true);
        GUI.color = _usingExternalTheme ? new Color(0.72f, 0.88f, 1f, 0.96f) : Color.white;

        GUI.DrawTexture(rect, _panelTex, ScaleMode.StretchToFill, true);
        if (_usingExternalTheme)
        {
            DrawRect(rect, new Color(0.10f, 0.22f, 0.40f, 0.14f));
        }
        DrawRect(new Rect(rect.x, rect.y, rect.width, 1f), new Color(0.62f, 0.90f, 1f, 0.30f));
        DrawRect(new Rect(rect.x, rect.yMax - 1f, rect.width, 1f), new Color(0.22f, 0.36f, 0.56f, 0.48f));
        DrawRect(new Rect(rect.x, rect.y, 1f, rect.height), new Color(0.52f, 0.76f, 1f, 0.20f));
        DrawRect(new Rect(rect.xMax - 1f, rect.y, 1f, rect.height), new Color(0.18f, 0.30f, 0.50f, 0.40f));

        GUI.color = old;
    }

    public static void DrawInset(Rect rect)
    {
        EnsureInit();
        Color old = GUI.color;
        GUI.color = _usingExternalTheme ? new Color(0.70f, 0.86f, 1f, 0.95f) : Color.white;
        GUI.DrawTexture(rect, _insetTex, ScaleMode.StretchToFill, true);
        GUI.color = old;
        if (_usingExternalTheme)
        {
            DrawRect(rect, new Color(0.03f, 0.08f, 0.15f, 0.20f));
        }
        DrawRect(new Rect(rect.x, rect.y, rect.width, 1f), new Color(0.55f, 0.84f, 1f, 0.18f));
        DrawRect(new Rect(rect.x, rect.yMax - 1f, rect.width, 1f), new Color(0f, 0f, 0f, 0.24f));
    }

    public static void DrawRow(Rect rect, bool emphasize = false)
    {
        EnsureInit();
        Color c = emphasize
            ? new Color(0.25f, 0.56f, 0.86f, 0.18f)
            : new Color(0.17f, 0.28f, 0.45f, 0.14f);
        DrawRect(rect, c);
    }

    public static void DrawSeparator(Rect rect)
    {
        DrawRect(rect, new Color(0.45f, 0.72f, 0.95f, 0.24f));
    }

    public static void SkinButton(GUIStyle style)
    {
        EnsureInit();
        style.normal.background = _buttonTex;
        style.hover.background = _buttonHoverTex;
        style.active.background = _buttonActiveTex;
        style.focused.background = _buttonTex;
        style.normal.textColor = new Color(0.92f, 0.98f, 1f);
        style.hover.textColor = Color.white;
        style.active.textColor = new Color(0.84f, 0.96f, 1f);
        if (_usingExternalTheme)
        {
            style.padding = new RectOffset(16, 16, 10, 10);
            style.border = new RectOffset(28, 28, 28, 28);
        }
        else
        {
            style.padding = new RectOffset(8, 8, 6, 6);
            style.border = new RectOffset(3, 3, 3, 3);
        }
    }

    public static void SkinTab(GUIStyle style, bool active)
    {
        EnsureInit();
        style.normal.background = active ? _tabActiveTex : _tabTex;
        style.hover.background = active ? _tabActiveTex : _buttonHoverTex;
        style.active.background = active ? _tabActiveTex : _buttonActiveTex;
        style.focused.background = active ? _tabActiveTex : _tabTex;
        style.normal.textColor = active ? new Color(0.78f, 0.97f, 1f) : new Color(0.79f, 0.89f, 0.98f);
        style.hover.textColor = Color.white;
        style.active.textColor = new Color(0.74f, 0.95f, 1f);
        if (_usingExternalTheme)
        {
            style.padding = new RectOffset(14, 14, 8, 8);
            style.border = new RectOffset(20, 20, 20, 20);
        }
        else
        {
            style.border = new RectOffset(3, 3, 3, 3);
        }
    }

    public static void SkinInput(GUIStyle style)
    {
        EnsureInit();
        style.normal.background = _inputTex;
        style.focused.background = _inputTex;
        style.active.background = _inputTex;
        style.normal.textColor = new Color(0.90f, 0.97f, 1f);
        style.focused.textColor = Color.white;
        if (_usingExternalTheme)
        {
            style.padding = new RectOffset(14, 14, 8, 8);
            style.border = new RectOffset(18, 18, 18, 18);
        }
        else
        {
            style.padding = new RectOffset(8, 8, 6, 6);
            style.border = new RectOffset(2, 2, 2, 2);
        }
    }

    public static void DrawRect(Rect rect, Color color)
    {
        EnsureInit();
        Color old = GUI.color;
        GUI.color = color;
        GUI.DrawTexture(rect, _whiteTex, ScaleMode.StretchToFill, true);
        GUI.color = old;
    }

    private static void DrawGlow(Vector2 center, float size, Color color)
    {
        EnsureInit();
        Rect rect = new Rect(center.x - size * 0.5f, center.y - size * 0.5f, size, size);
        Color old = GUI.color;
        GUI.color = color;
        GUI.DrawTexture(rect, _softGlowTex, ScaleMode.StretchToFill, true);
        GUI.color = old;
    }

    private static Texture2D CreateSolidTexture(Color color)
    {
        Texture2D tex = new Texture2D(1, 1, TextureFormat.RGBA32, false);
        tex.SetPixel(0, 0, color);
        tex.Apply();
        return tex;
    }

    private static Texture2D CreateVerticalGradientTexture(
        int width, int height, Color top, Color bottom, float noiseAmount)
    {
        Texture2D tex = new Texture2D(width, height, TextureFormat.RGBA32, false);
        tex.filterMode = FilterMode.Bilinear;
        tex.wrapMode = TextureWrapMode.Clamp;
        for (int y = 0; y < height; y++)
        {
            float t = y / (float)(height - 1);
            for (int x = 0; x < width; x++)
            {
                Color c = Color.Lerp(bottom, top, t);
                if (noiseAmount > 0f)
                {
                    float n = Mathf.PerlinNoise(x * 0.13f, y * 0.13f);
                    float k = 1f - noiseAmount * 0.5f + n * noiseAmount;
                    c *= k;
                }
                tex.SetPixel(x, y, c);
            }
        }
        tex.Apply();
        return tex;
    }

    private static Texture2D CreateSoftCircleTexture(int resolution)
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
        return tex;
    }
}
