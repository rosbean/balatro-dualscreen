/*
 * balatro-dualscreen-thor -- native Lua <-> Java bridge.
 * Copyright (C) 2026  balatro-dualscreen-thor contributors
 *
 * The JNI call pattern is derived from BanjoRecomp Android (GPL-3.0):
 *   src/game/recomp_api.cpp:256-310
 * Specifically: acquiring JNIEnv and the activity through SDL, resolving a
 * static method on the activity's own class, and the local-reference hygiene
 * afterwards -- DeleteLocalRef on BOTH the class and the activity, with
 * ExceptionCheck/ExceptionClear around the call. Omitting either leak is easy
 * and produces a slow reference-table exhaustion that is miserable to diagnose.
 * Upstream: https://github.com/BanjoRecomp/BanjoRecomp
 *
 * Adapted rather than copied: Banjo pushes eighteen fixed ints because its
 * stats are a fixed struct. Balatro's snapshot contains a variable-length card
 * array, so this passes a single string instead. That keeps the JNI surface at
 * two functions and means a schema change never requires touching C again.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#include <jni.h>
#include <android/log.h>
#include <string.h>

#include "SDL_system.h"

#include "lua.h"
#include "lauxlib.h"

#define TAG "BalatroDS"
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

/*
 * Every call re-acquires env, activity and class rather than caching them.
 *
 * That is deliberate. JNIEnv is per-thread, and local references are only
 * valid for the duration of the native call that created them -- caching
 * either across calls is undefined behaviour that happens to work until it
 * does not. The cost is a few microseconds against a push that happens on hand
 * mutation, not per frame.
 */
typedef struct {
    JNIEnv *env;
    jobject activity;
    jclass  clazz;
} ds_ctx;

static int ds_ctx_acquire(ds_ctx *c) {
    c->env = NULL;
    c->activity = NULL;
    c->clazz = NULL;

    c->env = (JNIEnv *) SDL_AndroidGetJNIEnv();
    if (c->env == NULL) {
        return 0;
    }

    c->activity = (jobject) SDL_AndroidGetActivity();
    if (c->activity == NULL) {
        LOGW("dsbridge: SDL activity unavailable");
        return 0;
    }

    c->clazz = (*c->env)->GetObjectClass(c->env, c->activity);
    if (c->clazz == NULL) {
        (*c->env)->ExceptionClear(c->env);
        (*c->env)->DeleteLocalRef(c->env, c->activity);
        c->activity = NULL;
        LOGW("dsbridge: activity class unavailable");
        return 0;
    }
    return 1;
}

static void ds_ctx_release(ds_ctx *c) {
    if (c->env == NULL) {
        return;
    }
    if ((*c->env)->ExceptionCheck(c->env)) {
        LOGW("dsbridge: pending JNI exception, clearing");
        (*c->env)->ExceptionDescribe(c->env);
        (*c->env)->ExceptionClear(c->env);
    }
    if (c->clazz != NULL) {
        (*c->env)->DeleteLocalRef(c->env, c->clazz);
        c->clazz = NULL;
    }
    if (c->activity != NULL) {
        (*c->env)->DeleteLocalRef(c->env, c->activity);
        c->activity = NULL;
    }
}

/*
 * dsbridge.push(snapshot_string) -> boolean
 *
 * Hands a serialised snapshot to the Java side. Returns false if the bridge
 * could not be reached, so Lua can fall back to single-screen behaviour rather
 * than assuming the push landed.
 */
static int l_push(lua_State *L) {
    size_t len = 0;
    const char *payload = luaL_checklstring(L, 1, &len);

    ds_ctx c;
    if (!ds_ctx_acquire(&c)) {
        lua_pushboolean(L, 0);
        return 1;
    }

    int ok = 0;
    jmethodID mid = (*c.env)->GetStaticMethodID(
            c.env, c.clazz, "pushSnapshotFromNative", "(Ljava/lang/String;)V");
    if (mid == NULL) {
        (*c.env)->ExceptionClear(c.env);
        LOGW("dsbridge: pushSnapshotFromNative not found");
    } else {
        jstring js = (*c.env)->NewStringUTF(c.env, payload);
        if (js != NULL) {
            (*c.env)->CallStaticVoidMethod(c.env, c.clazz, mid, js);
            (*c.env)->DeleteLocalRef(c.env, js);
            ok = 1;
        }
    }

    ds_ctx_release(&c);
    lua_pushboolean(L, ok);
    return 1;
}

/*
 * dsbridge.poll() -> string | nil
 *
 * Drains one semantic event from the Java-side queue. Lua calls this in a loop
 * from a wrapped love.update until it returns nil.
 *
 * Deliberately NOT injecting synthetic SDL input events: those would be
 * delivered against display 0's window, so a tap at (x,y) on screen 2 would act
 * on whatever is at (x,y) on screen 1. See the build plan's rejected
 * approaches.
 */
static int l_poll(lua_State *L) {
    ds_ctx c;
    if (!ds_ctx_acquire(&c)) {
        lua_pushnil(L);
        return 1;
    }

    int pushed = 0;
    jmethodID mid = (*c.env)->GetStaticMethodID(
            c.env, c.clazz, "pollEventFromNative", "()Ljava/lang/String;");
    if (mid == NULL) {
        (*c.env)->ExceptionClear(c.env);
        LOGW("dsbridge: pollEventFromNative not found");
    } else {
        jstring js = (jstring) (*c.env)->CallStaticObjectMethod(c.env, c.clazz, mid);
        if (js != NULL) {
            const char *s = (*c.env)->GetStringUTFChars(c.env, js, NULL);
            if (s != NULL) {
                lua_pushstring(L, s);
                (*c.env)->ReleaseStringUTFChars(c.env, js, s);
                pushed = 1;
            }
            (*c.env)->DeleteLocalRef(c.env, js);
        }
    }

    ds_ctx_release(&c);
    if (!pushed) {
        lua_pushnil(L);
    }
    return 1;
}

/*
 * dsbridge.available() -> boolean
 *
 * True when the JNI path resolves and the Java side exposes what we expect.
 * This is what DS.active is derived from: a device with no companion, or a
 * build where the Java half is missing, reports false and the overlay stays on
 * its single-screen path.
 */
static int l_available(lua_State *L) {
    ds_ctx c;
    if (!ds_ctx_acquire(&c)) {
        lua_pushboolean(L, 0);
        return 1;
    }

    jmethodID mid = (*c.env)->GetStaticMethodID(
            c.env, c.clazz, "isCompanionShowingFromNative", "()Z");
    int showing = 0;
    if (mid == NULL) {
        (*c.env)->ExceptionClear(c.env);
    } else {
        showing = (*c.env)->CallStaticBooleanMethod(c.env, c.clazz, mid) ? 1 : 0;
    }

    ds_ctx_release(&c);
    lua_pushboolean(L, showing);
    return 1;
}

/*
 * dsbridge.push_pixels(bytes, w, h) -> boolean
 *
 * Ships a raw RGBA8 frame to Java as a byte[].
 *
 * Deliberately NOT reusing push()'s jstring path: NewStringUTF would treat the
 * pixel data as modified-UTF8, mangling every byte >= 0x80 and inflating the
 * payload. Binary goes as a byte array or not at all.
 *
 * A full 1240x1080 frame is 5.4 MB, so this is the expensive call in the
 * system and the one Task 5.0 exists to measure.
 */
static int l_push_pixels(lua_State *L) {
    size_t len = 0;
    const char *px = luaL_checklstring(L, 1, &len);
    int w = (int) luaL_checkinteger(L, 2);
    int h = (int) luaL_checkinteger(L, 3);

    ds_ctx c;
    if (!ds_ctx_acquire(&c)) {
        lua_pushboolean(L, 0);
        return 1;
    }

    int ok = 0;
    jmethodID mid = (*c.env)->GetStaticMethodID(
            c.env, c.clazz, "pushFrameFromNative", "([BII)V");
    if (mid == NULL) {
        (*c.env)->ExceptionClear(c.env);
        LOGW("dsbridge: pushFrameFromNative not found");
    } else {
        jbyteArray arr = (*c.env)->NewByteArray(c.env, (jsize) len);
        if (arr != NULL) {
            (*c.env)->SetByteArrayRegion(c.env, arr, 0, (jsize) len,
                                         (const jbyte *) px);
            (*c.env)->CallStaticVoidMethod(c.env, c.clazz, mid, arr, w, h);
            (*c.env)->DeleteLocalRef(c.env, arr);
            ok = 1;
        } else {
            (*c.env)->ExceptionClear(c.env);
            LOGW("dsbridge: could not allocate %zu byte frame", len);
        }
    }

    ds_ctx_release(&c);
    lua_pushboolean(L, ok);
    return 1;
}

/*
 * dsbridge.push_pixels2(ptr, size, w, h) -> boolean
 *
 * Task 9.0, the zero-copy frame path. `ptr` is Data:getPointer() on the
 * LOVE-side ImageData -- the pixels where the readback left them. They are
 * memcpy'd once, directly into a persistent Java direct ByteBuffer, and the
 * UI thread is told the frame is ready.
 *
 * Replaces, per push: a 5.2 MB Lua string (ImageData:getString), a 5.2 MB
 * Java byte[] (NewByteArray), and one of the Java-side copies. The buffer
 * OBJECT doubles as the lock: MonitorEnter here pairs with synchronized(buf)
 * around the Bitmap copy in CompanionProbeView, so the UI thread can never
 * observe a half-written frame.
 *
 * All calls arrive on the single LOVE thread, so the cached globals need no
 * locking of their own.
 */
static jobject g_frame_buf = NULL;   /* GlobalRef to the direct ByteBuffer */
static void   *g_frame_addr = NULL;
static jlong   g_frame_cap = 0;
static int     g_frame_w = 0, g_frame_h = 0;

static int l_push_pixels2(lua_State *L) {
    luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);
    const void *px = lua_touserdata(L, 1);
    lua_Integer size = luaL_checkinteger(L, 2);
    int w = (int) luaL_checkinteger(L, 3);
    int h = (int) luaL_checkinteger(L, 4);

    if (px == NULL || size <= 0 || w <= 0 || h <= 0) {
        lua_pushboolean(L, 0);
        return 1;
    }

    ds_ctx c;
    if (!ds_ctx_acquire(&c)) {
        lua_pushboolean(L, 0);
        return 1;
    }

    int ok = 0;

    /* (Re)acquire the shared buffer when the panel size changes. */
    if (g_frame_buf == NULL || g_frame_w != w || g_frame_h != h) {
        jmethodID acq = (*c.env)->GetStaticMethodID(
                c.env, c.clazz, "acquireFrameBufferFromNative",
                "(II)Ljava/nio/ByteBuffer;");
        if (acq == NULL) {
            (*c.env)->ExceptionClear(c.env);
            LOGW("dsbridge: acquireFrameBufferFromNative not found");
            ds_ctx_release(&c);
            lua_pushboolean(L, 0);
            return 1;
        }
        jobject buf = (*c.env)->CallStaticObjectMethod(c.env, c.clazz, acq, w, h);
        if (buf == NULL) {
            (*c.env)->ExceptionClear(c.env);
            ds_ctx_release(&c);
            lua_pushboolean(L, 0);
            return 1;
        }
        if (g_frame_buf != NULL) {
            (*c.env)->DeleteGlobalRef(c.env, g_frame_buf);
        }
        g_frame_buf = (*c.env)->NewGlobalRef(c.env, buf);
        (*c.env)->DeleteLocalRef(c.env, buf);
        g_frame_addr = (*c.env)->GetDirectBufferAddress(c.env, g_frame_buf);
        g_frame_cap = (*c.env)->GetDirectBufferCapacity(c.env, g_frame_buf);
        g_frame_w = w;
        g_frame_h = h;
        if (g_frame_addr == NULL || g_frame_cap <= 0) {
            LOGW("dsbridge: shared buffer has no direct address");
            (*c.env)->DeleteGlobalRef(c.env, g_frame_buf);
            g_frame_buf = NULL;
            ds_ctx_release(&c);
            lua_pushboolean(L, 0);
            return 1;
        }
    }

    {
        size_t n = (size_t) size;
        if ((jlong) n > g_frame_cap) n = (size_t) g_frame_cap;

        if ((*c.env)->MonitorEnter(c.env, g_frame_buf) == 0) {
            memcpy(g_frame_addr, px, n);
            (*c.env)->MonitorExit(c.env, g_frame_buf);

            jmethodID ready = (*c.env)->GetStaticMethodID(
                    c.env, c.clazz, "frameReadyFromNative", "(II)V");
            if (ready != NULL) {
                (*c.env)->CallStaticVoidMethod(c.env, c.clazz, ready, w, h);
                ok = 1;
            } else {
                (*c.env)->ExceptionClear(c.env);
            }
        }
    }

    ds_ctx_release(&c);
    lua_pushboolean(L, ok);
    return 1;
}

/* dsbridge.panel_size() -> "WxH" | nil */
static int l_panel_size(lua_State *L) {
    ds_ctx c;
    if (!ds_ctx_acquire(&c)) {
        lua_pushnil(L);
        return 1;
    }
    int pushed = 0;
    jmethodID mid = (*c.env)->GetStaticMethodID(
            c.env, c.clazz, "getCompanionSizeFromNative", "()Ljava/lang/String;");
    if (mid == NULL) {
        (*c.env)->ExceptionClear(c.env);
    } else {
        jstring js = (jstring) (*c.env)->CallStaticObjectMethod(c.env, c.clazz, mid);
        if (js != NULL) {
            const char *s = (*c.env)->GetStringUTFChars(c.env, js, NULL);
            if (s != NULL) {
                lua_pushstring(L, s);
                (*c.env)->ReleaseStringUTFChars(c.env, js, s);
                pushed = 1;
            }
            (*c.env)->DeleteLocalRef(c.env, js);
        }
    }
    ds_ctx_release(&c);
    if (!pushed) lua_pushnil(L);
    return 1;
}

/*
 * dsbridge.set_leds(r, g, b) -> boolean
 *
 * Forwards a joystick LED colour to Java. Fire-and-forget; on hardware
 * without the vendor LED service the Java side is a silent no-op.
 */
static int l_set_leds(lua_State *L) {
    int r = (int) luaL_checkinteger(L, 1);
    int g = (int) luaL_checkinteger(L, 2);
    int b = (int) luaL_checkinteger(L, 3);

    ds_ctx c;
    if (!ds_ctx_acquire(&c)) {
        lua_pushboolean(L, 0);
        return 1;
    }

    int ok = 0;
    jmethodID mid = (*c.env)->GetStaticMethodID(
            c.env, c.clazz, "setLedsFromNative", "(III)V");
    if (mid == NULL) {
        (*c.env)->ExceptionClear(c.env);
        LOGW("dsbridge: setLedsFromNative not found");
    } else {
        (*c.env)->CallStaticVoidMethod(c.env, c.clazz, mid, r, g, b);
        ok = 1;
    }
    ds_ctx_release(&c);
    lua_pushboolean(L, ok);
    return 1;
}

static const luaL_Reg dsbridge_lib[] = {
    { "panel_size", l_panel_size },
    { "push_pixels", l_push_pixels },
    { "push_pixels2", l_push_pixels2 },
    { "set_leds", l_set_leds },
    { "push",      l_push },
    { "poll",      l_poll },
    { "available", l_available },
    { NULL, NULL }
};

int luaopen_dsbridge(lua_State *L) {
    LOGI("dsbridge: native module loaded");
#if LUA_VERSION_NUM >= 502
    luaL_newlib(L, dsbridge_lib);
#else
    luaL_register(L, "dsbridge", dsbridge_lib);
#endif
    return 1;
}
