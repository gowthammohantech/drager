# Only for `-PsbTestBuildType=release` (instrumented tests against the minified app).
#
# The test APK resolves shared libraries (androidx.test, tracing, Compose test internals, Kotlin) and
# test-only app classes (in-memory stores, test hooks) from the app APK, so the app must keep them for
# this run. What stays shrunk, optimized and (outside org.bouncycastle.tls) obfuscated is BouncyCastle,
# which is the release-only risk this run exists to check.
-keep class com.spatialbridge.** { *; }
-keep class androidx.** { *; }
-keep class kotlin.** { *; }
-keep class kotlinx.** { *; }

# The test APK (testProguardFiles) pulls in Error Prone annotations that reference javax.lang.model.
-dontwarn javax.lang.model.**
