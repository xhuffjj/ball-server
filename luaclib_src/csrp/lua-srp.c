#include <lua.h>
#include <lauxlib.h>

#include <ctype.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#include "srp.h"

/*
 * Lua C API 速记：
 * - luaL_checklstring: 取 Lua 字符串（允许二进制），并返回长度
 * - lua_newuserdata: 在 Lua 堆上创建 C 对象内存
 * - luaL_newmetatable + __index: 给 userdata 绑定“方法表”
 * - luaL_setfuncs/luaL_newlib: 导出方法或模块函数
 */

/* Lua userdata 的元表名 */
#define SRP_VERIFIER_META "SRP_VERIFIER_META"
#define SRP_USER_META "SRP_USER_META"

/* 默认参数：对齐 SRP.NET 常见默认组合 */
#define DEFAULT_ALG SRP_SHA256
#define DEFAULT_NG_TYPE SRP_NG_2048
#define DEFAULT_RFC5054_COMPAT 1

/* C 层对象包装，交给 Lua GC 管理生命周期 */
typedef struct {
    struct SRPVerifier *ver;
} lsrp_verifier;

typedef struct {
    struct SRPUser *usr;
} lsrp_user;

typedef struct {
    /* 哈希算法（如 SRP_SHA256） */
    SRP_HashAlgorithm alg;
    /* N/g 参数组类型（如 SRP_NG_2048） */
    SRP_NGType ng_type;
    /* 自定义 N 的 16 进制字符串，仅 ng_type=SRP_NG_CUSTOM 时使用 */
    const char *n_hex;
    /* 自定义 g 的 16 进制字符串，仅 ng_type=SRP_NG_CUSTOM 时使用 */
    const char *g_hex;
    /* 1=按 RFC5054 兼容模式计算（通常建议开启，和 SRP.NET 更容易对齐） */
    int rfc5054_compat;
    /* 1=计算 x 时不包含用户名（兼容某些历史实现），默认 0 */
    int no_username_in_x;
} lsrp_params;

/* size_t（64位） -> unsigned int（32位） 的安全转换（luaL_checklstring 给你的长度是 size_t，csrp API 使用 unsigned int 长度） */
static unsigned int
check_len_u32(lua_State *L, size_t len, const char *name) {
    if (len > UINT_MAX) {
        luaL_error(L, "%s is too large", name);
    }
    return (unsigned int)len;
}
//忽略大小写的字符串相等比较，1为相等
static int
str_ieq(const char *a, const char *b) {
    /* case-insensitive 字符串比较，返回 1 表示相等 */
    while (*a && *b) {
        if (tolower((unsigned char)*a) != tolower((unsigned char)*b)) {
            return 0;
        }
        ++a;
        ++b;
    }
    return *a == '\0' && *b == '\0';
}
//在 Lua table 里按“多个候选字段名”依次查找，找到第一个非 nil 的值就返回成功，idx是表的栈索引，keys是候选键名数组（例如 {"alg","hash","Hash"}）
static int
table_get_any(lua_State *L, int idx, const char *const *keys, size_t nkeys) {
    size_t i;
    /* 把栈索引转换成绝对索引，避免后续压栈/弹栈导致 idx 漂移 */
    idx = lua_absindex(L, idx);
    for (i = 0; i < nkeys; ++i) {
        lua_getfield(L, idx, keys[i]);//从栈上第 idx 个位置的 table 里，取字段 keys[i] 的值，并把这个值压到栈顶
        if (!lua_isnil(L, -1)) {//栈顶的值不是nil
            return 1;
        }
        lua_pop(L, 1);//出栈
    }
    return 0;
}
// Lua 传入的 hash 参数解析成 SRP_HashAlgorithm 枚举”，支持整数或者字符串
static SRP_HashAlgorithm
parse_hash(lua_State *L, int idx) {
    /* 支持枚举值或字符串（sha256 / SRP_SHA256 等） */
    if (lua_isinteger(L, idx)) {//如果参数是整数
        lua_Integer v = lua_tointeger(L, idx);
        if (v >= SRP_SHA1 && v <= SRP_SHA512) {//若在合法范围（SRP_SHA1 到 SRP_SHA512）就直接返回
            return (SRP_HashAlgorithm)v;//整数 v 转成枚举类型 SRP_HashAlgorithm 后返回
        }
        luaL_error(L, "invalid hash enum value: %d", (int)v);
    }

    if (lua_isstring(L, idx)) {//如果参数是字符串，匹配到就返回对应枚举。匹配不到就报错：invalid hash value
        const char *s = lua_tostring(L, idx);
        if (str_ieq(s, "sha1") || str_ieq(s, "sha-1") || str_ieq(s, "SRP_SHA1")) {
            return SRP_SHA1;
        }
        if (str_ieq(s, "sha224") || str_ieq(s, "sha-224") || str_ieq(s, "SRP_SHA224")) {
            return SRP_SHA224;
        }
        if (str_ieq(s, "sha256") || str_ieq(s, "sha-256") || str_ieq(s, "SRP_SHA256")) {
            return SRP_SHA256;
        }
        if (str_ieq(s, "sha384") || str_ieq(s, "sha-384") || str_ieq(s, "SRP_SHA384")) {
            return SRP_SHA384;
        }
        if (str_ieq(s, "sha512") || str_ieq(s, "sha-512") || str_ieq(s, "SRP_SHA512")) {
            return SRP_SHA512;
        }
        luaL_error(L, "invalid hash value: %s", s);
    }

    luaL_error(L, "hash must be integer or string");//如果既不是整数也不是字符串
//报错：hash must be integer or string
    return DEFAULT_ALG;
}
// Lua 传入的 ng_type 参数解析成 SRP_NGType（SRP 的 N/g 参数组类型）。
static SRP_NGType
parse_ng_type(lua_State *L, int idx) {
    /* 支持枚举值或位数字符串（2048） */
    if (lua_isinteger(L, idx)) {//枚举整数（如 SRP_NG_2048 对应的值）

        lua_Integer v = lua_tointeger(L, idx);
        if (v >= SRP_NG_1024 && v <= SRP_NG_CUSTOM) {//如果在 SRP_NG_1024 ~ SRP_NG_CUSTOM 范围内，直接转成枚举返回。
            return (SRP_NGType)v;
        }
        switch ((int)v) {//位数整数（如 2048、4096）通过 switch 映射到对应枚举（2048 -> SRP_NG_2048）
        case 1024: return SRP_NG_1024;
        case 1536: return SRP_NG_1536;
        case 2048: return SRP_NG_2048;
        case 4096: return SRP_NG_4096;
        case 8192: return SRP_NG_8192;
        default:
            luaL_error(L, "invalid ng_type value: %d", (int)v);
        }
    }

    if (lua_isstring(L, idx)) {//字符串（如 "2048"、"SRP_NG_2048"、"custom"）
        const char *s = lua_tostring(L, idx);
        if (str_ieq(s, "1024") || str_ieq(s, "SRP_NG_1024")) return SRP_NG_1024;
        if (str_ieq(s, "1536") || str_ieq(s, "SRP_NG_1536")) return SRP_NG_1536;
        if (str_ieq(s, "2048") || str_ieq(s, "SRP_NG_2048")) return SRP_NG_2048;
        if (str_ieq(s, "4096") || str_ieq(s, "SRP_NG_4096")) return SRP_NG_4096;
        if (str_ieq(s, "8192") || str_ieq(s, "SRP_NG_8192")) return SRP_NG_8192;
        if (str_ieq(s, "custom") || str_ieq(s, "SRP_NG_CUSTOM")) return SRP_NG_CUSTOM;
        luaL_error(L, "invalid ng_type value: %s", s);
    }

    luaL_error(L, "ng_type must be integer or string");
    return DEFAULT_NG_TYPE;
}
//这个函数是把 Lua 参数“统一解析成 C 的布尔值（0/1）”
static int
parse_bool(lua_State *L, int idx, const char *field_name) {
    /* 容忍布尔/整数/字符串（true/false）三种传法 */
    if (lua_isboolean(L, idx)) {
        return lua_toboolean(L, idx);
    }
    if (lua_isinteger(L, idx)) {
        return lua_tointeger(L, idx) != 0;
    }
    if (lua_isstring(L, idx)) {
        const char *s = lua_tostring(L, idx);
        if (str_ieq(s, "1") || str_ieq(s, "true") || str_ieq(s, "yes")) return 1;
        if (str_ieq(s, "0") || str_ieq(s, "false") || str_ieq(s, "no")) return 0;
    }
    luaL_error(L, "%s must be boolean/integer/string(true|false)", field_name);
    return 0;
}
//把 Lua 传进来的 params 表，解析并写入 lsrp_params *p，同时做兼容和合法性校验
static void
parse_params(lua_State *L, int idx, lsrp_params *p) {
    /*
     * 兼容两套命名：
     * 1) 本模块传统参数：alg/ng_type/n_hex/g_hex/rfc5054_compat
     * 2) SRP.NET 风格参数：Hash/N/G/PaddedLength
     */
     //这些是“字段名别名列表”，给 parse_params 用来做兼容读取。
    //意思是同一个参数允许多种 key 名
    static const char *const hash_keys[] = {"alg", "hash", "Hash"};
    static const char *const ng_keys[] = {"ng_type", "ng", "NgType"};
    static const char *const n_keys[] = {"n_hex", "N"};
    static const char *const g_keys[] = {"g_hex", "G"};
    static const char *const rfc_keys[] = {"rfc5054_compat", "rfc5054", "RFC5054Compat"};
    static const char *const padded_len_keys[] = {"PaddedLength", "padded_length"};//PaddedLength 在 SRP 里通常指“大整数按固定字节长度补齐”的长度（一般就是 N 的字节数）
    static const char *const no_user_keys[] = {"no_username_in_x", "noUsernameInX"};
    //设默认值
    p->alg = DEFAULT_ALG;
    p->ng_type = DEFAULT_NG_TYPE;
    p->n_hex = NULL;
    p->g_hex = NULL;
    p->rfc5054_compat = DEFAULT_RFC5054_COMPAT;
    p->no_username_in_x = 0;

    if (lua_isnoneornil(L, idx)) {//如果没传 params（nil）就直接用默认值返回
        return;
    }

    idx = lua_absindex(L, idx);
    luaL_checktype(L, idx, LUA_TTABLE);//如果传了，要求它必须是 table。

    if (table_get_any(L, idx, hash_keys, sizeof(hash_keys) / sizeof(hash_keys[0]))) {//按 hash_keys（alg/hash/Hash）找第一个存在的字段，并把它的值压到栈顶
        p->alg = parse_hash(L, -1);//把栈顶这个值解析成 SRP_HashAlgorithm（如 SRP_SHA256）。
        lua_pop(L, 1);
    }

    if (table_get_any(L, idx, ng_keys, sizeof(ng_keys) / sizeof(ng_keys[0]))) {
        p->ng_type = parse_ng_type(L, -1);
        lua_pop(L, 1);
    }

    if (table_get_any(L, idx, n_keys, sizeof(n_keys) / sizeof(n_keys[0]))) {
        p->n_hex = luaL_checkstring(L, -1);
        lua_pop(L, 1);
    }

    if (table_get_any(L, idx, g_keys, sizeof(g_keys) / sizeof(g_keys[0]))) {
        p->g_hex = luaL_checkstring(L, -1);
        lua_pop(L, 1);
    }

    if (table_get_any(L, idx, rfc_keys, sizeof(rfc_keys) / sizeof(rfc_keys[0]))) {
        p->rfc5054_compat = parse_bool(L, -1, "rfc5054_compat");
        lua_pop(L, 1);
    }

    if (table_get_any(L, idx, padded_len_keys, sizeof(padded_len_keys) / sizeof(padded_len_keys[0]))) {
        if (lua_isnumber(L, -1)) {
            p->rfc5054_compat = (lua_tonumber(L, -1) > 0.0) ? 1 : 0;
        } else {
            p->rfc5054_compat = parse_bool(L, -1, "PaddedLength");
        }
        lua_pop(L, 1);
    }

    if (table_get_any(L, idx, no_user_keys, sizeof(no_user_keys) / sizeof(no_user_keys[0]))) {
        p->no_username_in_x = parse_bool(L, -1, "no_username_in_x");
        lua_pop(L, 1);
    }

    if ((p->n_hex != NULL) != (p->g_hex != NULL)) {
        luaL_error(L, "custom N/G requires both n_hex (or N) and g_hex (or G)");
    }

    if (p->n_hex != NULL) {
        p->ng_type = SRP_NG_CUSTOM;
    } else if (p->ng_type == SRP_NG_CUSTOM) {
        luaL_error(L, "ng_type/custom requires n_hex and g_hex");
    }
}

/*
 * 注册阶段：生成 salt + verifier
 * Lua: srp.create_verifier(username, password [, params]) -> salt, verifier
 */
static int
l_create_verifier(lua_State *L) {
    size_t pass_len = 0;
    const char *username = luaL_checkstring(L, 1);
    const unsigned char *password = (const unsigned char *)luaL_checklstring(L, 2, &pass_len);

    lsrp_params p;
    const unsigned char *bytes_s = NULL;
    const unsigned char *bytes_v = NULL;
    unsigned int len_s = 0;
    unsigned int len_v = 0;

    parse_params(L, 3, &p);//会把第 3 个 Lua 参数（params 配置表）读出来，解析后填充到 C 结构体 p（lsrp_params）里。
//如果第 3 个参数是 nil/没传，就给 p 填默认值

    srp_create_salted_verification_key(
        p.alg, p.ng_type, username, password, check_len_u32(L, pass_len, "password length"),
        &bytes_s, &len_s, &bytes_v, &len_v, p.n_hex, p.g_hex
    );

    if (bytes_s == NULL || bytes_v == NULL) {
        return luaL_error(L, "failed to create verifier");
    }

    lua_pushlstring(L, (const char *)bytes_s, (size_t)len_s);
    lua_pushlstring(L, (const char *)bytes_v, (size_t)len_v);

    free((void *)bytes_s);
    free((void *)bytes_v);
    return 2;
}

/*
 * 客户端阶段1：创建 user 会话并生成 A
 * Lua: srp.create_client(username, password [, params]) -> client_session, A
 */
static int
l_create_client(lua_State *L) {
    size_t pass_len = 0;
    const char *username = luaL_checkstring(L, 1);
    const unsigned char *password = (const unsigned char *)luaL_checklstring(L, 2, &pass_len);

    lsrp_params p;
    struct SRPUser *usr;
    const char *auth_username = NULL;
    const unsigned char *bytes_A = NULL;
    unsigned int len_A = 0;
    lsrp_user *obj;

    parse_params(L, 3, &p);

    usr = srp_user_new(
        p.alg, p.ng_type, username, password, check_len_u32(L, pass_len, "password length"),
        p.n_hex, p.g_hex, p.rfc5054_compat
    );
    if (usr == NULL) {
        return luaL_error(L, "failed to create user");
    }

    if (p.no_username_in_x) {
        /* 某些实现把 x 算成 H(s | H(P))，不包含用户名 I */
        srp_user_set_no_username_in_x(usr, true);
    }

    srp_user_start_authentication(usr, &auth_username, &bytes_A, &len_A);
    (void)auth_username;

    if (bytes_A == NULL) {
        srp_user_delete(usr);
        return luaL_error(L, "failed to start authentication");
    }

    obj = (lsrp_user *)lua_newuserdata(L, sizeof(*obj));
    obj->usr = usr;
    luaL_getmetatable(L, SRP_USER_META);
    lua_setmetatable(L, -2);

    lua_pushlstring(L, (const char *)bytes_A, (size_t)len_A);
    return 2;
}

/*
 * 服务端阶段1：根据 username/salt/verifier/A 创建 verifier 会话并生成 B
 * Lua: srp.create_session(username, salt, verifier, A [, params]) -> server_session, B
 * 失败时返回: nil, err
 */
static int
l_create_session(lua_State *L) {
    size_t s_len = 0;
    size_t v_len = 0;
    size_t a_len = 0;
    const char *username = luaL_checkstring(L, 1);
    const unsigned char *bytes_s = (const unsigned char *)luaL_checklstring(L, 2, &s_len);
    const unsigned char *bytes_v = (const unsigned char *)luaL_checklstring(L, 3, &v_len);
    const unsigned char *bytes_A = (const unsigned char *)luaL_checklstring(L, 4, &a_len);
    lsrp_params p;
    const unsigned char *bytes_B = NULL;
    unsigned int len_B = 0;
    struct SRPVerifier *ver;
    lsrp_verifier *obj;

    parse_params(L, 5, &p);

    ver = srp_verifier_new(
        p.alg, p.ng_type, username,
        bytes_s, check_len_u32(L, s_len, "salt length"),
        bytes_v, check_len_u32(L, v_len, "verifier length"),
        bytes_A, check_len_u32(L, a_len, "A length"),
        &bytes_B, &len_B, p.n_hex, p.g_hex, p.rfc5054_compat
    );

    if (ver == NULL) {//一般是底层初始化失败（内存/BN/OpenSSL 处理失败，或自定义参数不合法
        lua_pushnil(L);
        lua_pushliteral(L, "failed to create server session");
        return 2;
    }

    if (bytes_B == NULL) {//这通常是客户端 A 没通过 SRP-6a 安全检查（典型是非法 A，如 A % N == 0
        srp_verifier_delete(ver);
        lua_pushnil(L);
        lua_pushliteral(L, "invalid client public key A");
        return 2;
    }

    obj = (lsrp_verifier *)lua_newuserdata(L, sizeof(*obj));
    obj->ver = ver;
    luaL_getmetatable(L, SRP_VERIFIER_META);
    lua_setmetatable(L, -2);

    lua_pushlstring(L, (const char *)bytes_B, (size_t)len_B);
    return 2;
}

/*
 * 客户端阶段2：处理 salt/B，计算 M1
 * Lua: client_session:process_challenge(salt, B) -> M1
 * 失败时返回: nil, err
 */
static int
l_user_process_challenge(lua_State *L) {
    lsrp_user *obj = (lsrp_user *)luaL_checkudata(L, 1, SRP_USER_META);
    size_t s_len = 0;
    size_t b_len = 0;
    const unsigned char *bytes_s = (const unsigned char *)luaL_checklstring(L, 2, &s_len);
    const unsigned char *bytes_B = (const unsigned char *)luaL_checklstring(L, 3, &b_len);
    const unsigned char *bytes_M = NULL;
    unsigned int len_M = 0;

    srp_user_process_challenge(
        obj->usr,
        bytes_s, check_len_u32(L, s_len, "salt length"),
        bytes_B, check_len_u32(L, b_len, "B length"),
        &bytes_M, &len_M
    );

    if (bytes_M == NULL) {//服务端公钥 B 不合法，没通过 SRP-6a 安全检查（常见是 B % N == 0 或格式异常）
        lua_pushnil(L);
        lua_pushliteral(L, "invalid server public key B");
        return 2;
    }

    lua_pushlstring(L, (const char *)bytes_M, (size_t)len_M);
    return 1;
}

/*
 * 服务端阶段2：验证客户端 M1，返回 HAMK(M2)
 * Lua: server_session:verify(M1) -> M2 | nil
 * 注意：先校验 M1 长度，避免底层越界读取
 */
static int
l_verifier_verify(lua_State *L) {
    lsrp_verifier *obj = (lsrp_verifier *)luaL_checkudata(L, 1, SRP_VERIFIER_META);
    size_t m_len = 0;
    const unsigned char *bytes_M = (const unsigned char *)luaL_checklstring(L, 2, &m_len);
    const unsigned char *bytes_HAMK = NULL;
    int expected_len = srp_verifier_get_session_key_length(obj->ver);

    if (expected_len <= 0) {
        lua_pushnil(L);
        lua_pushliteral(L, "invalid verifier session key length");
        return 2;
    }

    if (m_len != (size_t)expected_len) {
        lua_pushnil(L);
        lua_pushfstring(L, "invalid M1 length: got %d, expected %d", (int)m_len, expected_len);
        return 2;
    }

    srp_verifier_verify_session(obj->ver, bytes_M, &bytes_HAMK);

    if (bytes_HAMK == NULL) {//验证失败：bytes_HAMK == NULL，返回 nil
        lua_pushnil(L);
        return 1;
    }

    lua_pushlstring(L, (const char *)bytes_HAMK, (size_t)expected_len);//验证通过：bytes_HAMK 非空，返回给客户端
    return 1;
}

/*
 * 客户端阶段3：验证服务端 M2(HAMK)
 * Lua: client_session:verify(M2) -> bool
 * 注意：先校验 HAMK 长度，避免底层越界读取
 */
static int
l_user_verify(lua_State *L) {
    lsrp_user *obj = (lsrp_user *)luaL_checkudata(L, 1, SRP_USER_META);
    size_t hamk_len = 0;
    const unsigned char *bytes_HAMK = (const unsigned char *)luaL_checklstring(L, 2, &hamk_len);
    int expected_len = srp_user_get_session_key_length(obj->usr);

    if (expected_len <= 0) {
        lua_pushboolean(L, 0);
        lua_pushliteral(L, "invalid user session key length");
        return 2;
    }

    if (hamk_len != (size_t)expected_len) {
        lua_pushboolean(L, 0);
        lua_pushfstring(L, "invalid HAMK length: got %d, expected %d", (int)hamk_len, expected_len);
        return 2;
    }

    srp_user_verify_session(obj->usr, bytes_HAMK);
    lua_pushboolean(L, srp_user_is_authenticated(obj->usr));//成功：返回 true
    //失败：通常返回 false
    return 1;
}

/* 服务端获取协商后的 session key */
static int
l_verifier_get_key(lua_State *L) {
    lsrp_verifier *obj = (lsrp_verifier *)luaL_checkudata(L, 1, SRP_VERIFIER_META);
    int key_len = 0;
    const unsigned char *key = srp_verifier_get_session_key(obj->ver, &key_len);

    if (key == NULL) {
        lua_pushnil(L);
    } else {
        lua_pushlstring(L, (const char *)key, (size_t)key_len);
    }
    return 1;
}

/* verifier userdata 的 GC 回收 */
static int
l_verifier_gc(lua_State *L) {
    lsrp_verifier *obj = (lsrp_verifier *)luaL_checkudata(L, 1, SRP_VERIFIER_META);
    if (obj->ver != NULL) {
        srp_verifier_delete(obj->ver);
        obj->ver = NULL;
    }
    return 0;
}

/* 客户端获取协商后的 session key */
static int
l_user_get_key(lua_State *L) {
    lsrp_user *obj = (lsrp_user *)luaL_checkudata(L, 1, SRP_USER_META);
    int key_len = 0;
    const unsigned char *key = srp_user_get_session_key(obj->usr, &key_len);

    if (key == NULL) {
        lua_pushnil(L);
    } else {
        lua_pushlstring(L, (const char *)key, (size_t)key_len);
    }
    return 1;
}

/* user userdata 的 GC 回收 */
static int
l_user_gc(lua_State *L) {
    lsrp_user *obj = (lsrp_user *)luaL_checkudata(L, 1, SRP_USER_META);
    if (obj->usr != NULL) {
        srp_user_delete(obj->usr);
        obj->usr = NULL;
    }
    return 0;
}

static int
hex_value(unsigned char c) {
    /* 单个十六进制字符转 0~15；非法返回 -1 */
    if (c >= '0' && c <= '9') return (int)(c - '0');
    if (c >= 'a' && c <= 'f') return (int)(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return (int)(c - 'A' + 10);
    return -1;
}

/* 二进制 -> hex，便于和 .NET 侧参数/日志互转 */
static int
l_hex_encode(lua_State *L) {
    static const char hex_lut[] = "0123456789abcdef";
    size_t len = 0;
    const unsigned char *src = (const unsigned char *)luaL_checklstring(L, 1, &len);
    luaL_Buffer b; /* Lua 提供的可增长缓冲区 */
    char *dst;
    size_t i;

    dst = luaL_buffinitsize(L, &b, len * 2);
    for (i = 0; i < len; ++i) {
        dst[i * 2] = hex_lut[src[i] >> 4];
        dst[i * 2 + 1] = hex_lut[src[i] & 0x0F];
    }
    luaL_pushresultsize(&b, len * 2);
    return 1;
}

/* hex -> 二进制（支持可选 0x 前缀） */
static int
l_hex_decode(lua_State *L) {
    size_t len = 0;
    const unsigned char *src = (const unsigned char *)luaL_checklstring(L, 1, &len);
    luaL_Buffer b; /* 先校验，再一次性写入二进制结果 */
    unsigned char *dst;
    size_t i;
    size_t out_len;

    if (len >= 2 && src[0] == '0' && (src[1] == 'x' || src[1] == 'X')) {
        src += 2;
        len -= 2;
    }

    if ((len & 1) != 0) {
        lua_pushnil(L);
        lua_pushliteral(L, "hex string length must be even");
        return 2;
    }

    out_len = len / 2;
    for (i = 0; i < out_len; ++i) {
        int hi = hex_value(src[i * 2]);
        int lo = hex_value(src[i * 2 + 1]);
        if (hi < 0 || lo < 0) {
            lua_pushnil(L);
            lua_pushfstring(L, "invalid hex at byte index %d", (int)i);
            return 2;
        }
    }

    dst = (unsigned char *)luaL_buffinitsize(L, &b, out_len);
    for (i = 0; i < out_len; ++i) {
        int hi = hex_value(src[i * 2]);
        int lo = hex_value(src[i * 2 + 1]);
        dst[i] = (unsigned char)((hi << 4) | lo);
    }

    luaL_pushresultsize(&b, out_len);
    return 1;
}

/* server_session 方法表 */
static const struct luaL_Reg verifier_methods[] = {
    {"verify", l_verifier_verify},
    {"get_session_key", l_verifier_get_key},
    {"__gc", l_verifier_gc},
    {NULL, NULL}
};

/* client_session 方法表 */
static const struct luaL_Reg user_methods[] = {
    {"process_challenge", l_user_process_challenge},
    {"verify", l_user_verify},
    {"get_session_key", l_user_get_key},
    {"__gc", l_user_gc},
    {NULL, NULL}
};

/* srp 模块导出函数 */
static const struct luaL_Reg srp_funcs[] = {
    {"create_verifier", l_create_verifier},
    {"create_session", l_create_session},
    {"create_client", l_create_client},
    {"hex_encode", l_hex_encode},
    {"hex_decode", l_hex_decode},
    {NULL, NULL}
};

int
luaopen_srp(lua_State *L) {
    /* 注册服务端 session 元表 */
    luaL_newmetatable(L, SRP_VERIFIER_META);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    luaL_setfuncs(L, verifier_methods, 0);
    lua_pop(L, 1);

    /* 注册客户端 session 元表 */
    luaL_newmetatable(L, SRP_USER_META);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    luaL_setfuncs(L, user_methods, 0);
    lua_pop(L, 1);

    /* 注册模块函数 */
    luaL_newlib(L, srp_funcs);

    /* 导出 hash 常量 */
    lua_pushinteger(L, SRP_SHA1);
    lua_setfield(L, -2, "SHA1");
    lua_pushinteger(L, SRP_SHA224);
    lua_setfield(L, -2, "SHA224");
    lua_pushinteger(L, SRP_SHA256);
    lua_setfield(L, -2, "SHA256");
    lua_pushinteger(L, SRP_SHA384);
    lua_setfield(L, -2, "SHA384");
    lua_pushinteger(L, SRP_SHA512);
    lua_setfield(L, -2, "SHA512");

    /* 导出 NG 常量 */
    lua_pushinteger(L, SRP_NG_1024);
    lua_setfield(L, -2, "NG_1024");
    lua_pushinteger(L, SRP_NG_1536);
    lua_setfield(L, -2, "NG_1536");
    lua_pushinteger(L, SRP_NG_2048);
    lua_setfield(L, -2, "NG_2048");
    lua_pushinteger(L, SRP_NG_4096);
    lua_setfield(L, -2, "NG_4096");
    lua_pushinteger(L, SRP_NG_8192);
    lua_setfield(L, -2, "NG_8192");
    lua_pushinteger(L, SRP_NG_CUSTOM);
    lua_setfield(L, -2, "NG_CUSTOM");

    return 1;
}
