# PdfReader release R8 rules.
#
# Already applied automatically, so not repeated here:
#  - proguard-android-optimize.txt (AGP default)
#  - $FLUTTER_ROOT/packages/flutter_tools/gradle/flutter_proguard_rules.pro
#    (keeps FlutterPlugin implementations, dontwarn io.flutter.plugin.** / android.**)
#  - plugin consumer rules: package:jni (com.github.dart_lang.jni.**, kotlin.Unit/Result/
#    Continuation looked up by name), package:jni_flutter (com.github.dart_lang.jni_flutter.**),
#    android_file_picker (empty).
# PDFium is a native library (libpdfium.so via Dart native assets, loaded with dlopen),
# so it needs no Java keep rules.

# Looked up reflectively by the Flutter embedding (GeneratedPluginRegister).
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# Flutter's deferred-components support references Play Core, which we do not ship.
-dontwarn com.google.android.play.core.**

# package:path_provider_android uses JNI (jnigen) to call framework classes by name;
# those are platform classes and need no rule. Keep jni's own classes defensively
# in case a consumer rule is dropped by a plugin upgrade.
-keep class com.github.dart_lang.jni.** { *; }
-keep class com.github.dart_lang.jni_flutter.** { *; }

# Strip verbose/debug logging calls from the app's own Java/Kotlin code in release.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
}
