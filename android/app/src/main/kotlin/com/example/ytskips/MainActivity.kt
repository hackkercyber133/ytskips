package com.example.ytskips

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val prefs by lazy { getSharedPreferences(SkipService.PREFS, Context.MODE_PRIVATE) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "ytskips/methods").setMethodCallHandler { call, result ->
            when (call.method) {
                "getConfig" -> result.success(
                    mapOf(
                        "serviceOn" to isServiceEnabled(),
                        "enabled" to prefs.getBoolean("enabled", true),
                        "mute" to prefs.getBoolean("mute", true),
                        "skipped" to prefs.getInt("skipped", 0),
                        "unskippable" to prefs.getInt("unskippable", 0)
                    )
                )
                "setFlag" -> {
                    val key = call.argument<String>("key")
                    val value = call.argument<Boolean>("value")
                    if (key == null || value == null) result.error("ARG", "key/value null", null)
                    else {
                        prefs.edit().putBoolean(key, value).apply()
                        result.success(null)
                    }
                }
                "resetStats" -> {
                    prefs.edit().putInt("skipped", 0).putInt("unskippable", 0).apply()
                    result.success(null)
                }
                "openAccessibility" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "openAppInfo" -> {
                    startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "ytskips/events").setStreamHandler(object : EventChannel.StreamHandler {
            private val main = Handler(Looper.getMainLooper())
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                SkipService.listener = { m -> main.post { sink.success(m) } }
            }
            override fun onCancel(args: Any?) {
                SkipService.listener = null
            }
        })
    }

    private fun isServiceEnabled(): Boolean {
        val s = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
            ?: return false
        return s.contains(SkipService::class.java.name)
    }
}
