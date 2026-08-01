# balatro-dualscreen-thor -- native Lua <-> Java bridge for the second screen.
#
# love-android has a first-class slot for external Lua C modules; see
# ../lua-modules-readme.txt. One folder per module, and per that readme the
# LOCAL_MODULE_FILENAME must match the folder name (an AGP bug), and must carry
# no "lib" prefix or Lua's require() will not find it.
#
# Task 0.2 correction: love-android builds native code with ndkBuild via
# Android.mk, NOT CMake. The build plan originally said CMake.

LOCAL_PATH := $(call my-dir)
include $(CLEAR_VARS)

LOCAL_MODULE          := dsbridge
LOCAL_MODULE_FILENAME := dsbridge

LOCAL_SRC_FILES := dsbridge.c

# LuaJIT headers for the Lua C API, SDL headers for SDL_AndroidGetJNIEnv /
# SDL_AndroidGetActivity. Both live in this vendored tree.
LOCAL_C_INCLUDES := \
	$(LOCAL_PATH)/../../LuaJIT-2.1/src \
	$(LOCAL_PATH)/../../SDL2/include

# liblove carries both the Lua symbols and the statically-linked SDL2. The
# readme's advice is exactly this: "simply link the native library with
# liblove".
LOCAL_SHARED_LIBRARIES := liblove

LOCAL_LDLIBS := -llog

include $(BUILD_SHARED_LIBRARY)
