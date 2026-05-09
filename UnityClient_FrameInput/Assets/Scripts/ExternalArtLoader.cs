using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using UnityEngine;

/// <summary>
/// 运行时加载 Assets/Art 下的外部 PNG 资源，缺失时返回 null。
/// </summary>
public static class ExternalArtLoader
{
    private const bool ExternalArtEnabled = false;

    private static readonly Dictionary<string, Texture2D> TextureCache =
        new Dictionary<string, Texture2D>();
    private static readonly Dictionary<string, Sprite> SpriteCache =
        new Dictionary<string, Sprite>();

    public static Texture2D LoadTexture(
        string relativePath,
        FilterMode filterMode = FilterMode.Bilinear,
        TextureWrapMode wrapMode = TextureWrapMode.Clamp)
    {
        if (!ExternalArtEnabled)
            return null;

        if (string.IsNullOrEmpty(relativePath))
            return null;

        if (TextureCache.TryGetValue(relativePath, out Texture2D cachedTex))
            return cachedTex;

        string fullPath = ResolveFullPath(relativePath);
        if (!File.Exists(fullPath))
        {
            TextureCache[relativePath] = null;
            return null;
        }

        try
        {
            byte[] bytes = File.ReadAllBytes(fullPath);
            Texture2D tex = new Texture2D(2, 2, TextureFormat.RGBA32, false);
            if (!tex.LoadImage(bytes, false))
            {
                UnityEngine.Object.Destroy(tex);
                TextureCache[relativePath] = null;
                return null;
            }

            tex.filterMode = filterMode;
            tex.wrapMode = wrapMode;
            tex.name = "ExternalArt:" + relativePath;
            TextureCache[relativePath] = tex;
            return tex;
        }
        catch (Exception ex)
        {
            Debug.LogWarning($"[ExternalArt] 读取纹理失败: {relativePath}, {ex.Message}");
            TextureCache[relativePath] = null;
            return null;
        }
    }

    public static Sprite LoadSprite(string relativePath, float pixelsPerUnit = 0f)
    {
        if (!ExternalArtEnabled)
            return null;

        if (string.IsNullOrEmpty(relativePath))
            return null;

        string cacheKey = relativePath + "|" +
            pixelsPerUnit.ToString("F3", CultureInfo.InvariantCulture);
        if (SpriteCache.TryGetValue(cacheKey, out Sprite cachedSprite))
            return cachedSprite;

        Texture2D tex = LoadTexture(relativePath);
        if (tex == null)
        {
            SpriteCache[cacheKey] = null;
            return null;
        }

        float ppu = pixelsPerUnit;
        if (ppu <= 0f)
        {
            ppu = Mathf.Max(1f, Mathf.Min(tex.width, tex.height));
        }

        Sprite sprite = Sprite.Create(
            tex,
            new Rect(0f, 0f, tex.width, tex.height),
            new Vector2(0.5f, 0.5f),
            ppu);
        sprite.name = "ExternalSprite:" + relativePath;
        SpriteCache[cacheKey] = sprite;
        return sprite;
    }

    private static string ResolveFullPath(string relativePath)
    {
        string normalized = relativePath.Replace('\\', '/').TrimStart('/');
        string platformPath = normalized.Replace('/', Path.DirectorySeparatorChar);
        return Path.Combine(Application.dataPath, platformPath);
    }
}
