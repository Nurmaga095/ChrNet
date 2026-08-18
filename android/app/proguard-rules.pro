# Flutter engine entry points.
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# The embedding references Play Core for deferred components. The app does not
# use deferred components and does not depend on Play Core, so R8 would
# otherwise stop on the dangling references.
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**

# gomobile bindings for the v2ray core. The .aar ships the same rules as a
# consumer config, but R8 is easier to reason about when they are explicit.
-keep class go.** { *; }
-keep class libv2ray.** { *; }

# Entry points declared in AndroidManifest.xml and reached over the platform
# channel, never from Kotlin call sites R8 can see.
-keep class com.chrnet.vpn.XrayVpnService { *; }
-keep class com.chrnet.vpn.VpnTileService { *; }

# ML Kit barcode scanning loads its detector implementations reflectively.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-dontwarn com.google.mlkit.**

# Silence warnings for optional desugaring/annotation classes pulled in by
# transitive dependencies but never referenced at runtime.
-dontwarn javax.annotation.**
-dontwarn org.checkerframework.**
-dontwarn com.google.errorprone.annotations.**
