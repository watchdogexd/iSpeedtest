package com.watchdogexd.ispeedtest

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "ispeedtest/theme_preferences"
    private val preferencesName = "ispeedtest_preferences"
    private val themeColorIdKey = "theme_color_id"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        ).setMethodCallHandler { call, result ->
            val preferences = getSharedPreferences(preferencesName, MODE_PRIVATE)
            when (call.method) {
                "getThemeColorId" -> result.success(preferences.getString(themeColorIdKey, null))
                "setThemeColorId" -> {
                    val themeColorId = call.arguments as? String
                    if (themeColorId.isNullOrBlank()) {
                        result.error("invalid_theme_color_id", "Theme color id must not be empty.", null)
                        return@setMethodCallHandler
                    }

                    preferences.edit().putString(themeColorIdKey, themeColorId).apply()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
