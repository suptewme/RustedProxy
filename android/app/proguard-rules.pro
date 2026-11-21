# Rusty JNI surface must stay reachable.
-keep class dev.rustedproxy.app.RustBridge { *; }
-keepclasseswithmembernames class * { native <methods>; }
-keep class dev.rustedproxy.app.RustedVpnService { *; }
-keep class dev.rustedproxy.app.MainActivity { *; }
-keep class dev.rustedproxy.app.QsTileService { *; }
-keep class dev.rustedproxy.app.BootReceiver { *; }
