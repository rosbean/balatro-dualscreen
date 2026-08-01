# Add project specific ProGuard rules here.
# By default, the flags in this file are appended to flags specified
# in /Users/diglet/android-sdk-macosx/tools/proguard/proguard-android.txt
# You can edit the include path and order by changing the proguardFiles
# directive in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# Add any project specific keep options here:

# If your project uses WebView with JS, uncomment the following
# and specify the fully qualified class name to the JavaScript interface
# class:
#-keepclassmembers class fqcn.of.javascript.interface.for.webview {
#   public *;
#}

-keep class org.love2d.android.GameActivity { *; }
-keep class org.libsdl.app.** { *; }

# Native code resolves these by name through JNI, so R8 cannot see a caller.
# @Keep covers the annotated methods; this covers the classes wholesale.
-keep class com.balatro.dualscreen.BalatroActivity { *; }
-keep class com.balatro.dualscreen.companion.** { *; }
-keep class com.balatro.dualscreen.ThorLeds { *; }
-keepclassmembers class * {
    @androidx.annotation.Keep *;
}
