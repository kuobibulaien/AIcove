package com.example.aicove_flutter

import android.Manifest
import android.app.AlarmManager
import android.content.Context
import android.content.Intent
import android.content.ComponentName
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val SYSTEM_PROXY_CHANNEL = "com.example.aicove_flutter/system_proxy"
        private const val KEEP_ALIVE_CHANNEL = "com.example.aicove_flutter/keep_alive"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS

            val display = display
            if (display != null) {
                val modes = display.supportedModes
                val highestMode = modes.maxByOrNull { it.refreshRate }
                if (highestMode != null) {
                    val params = window.attributes
                    params.preferredDisplayModeId = highestMode.modeId
                    window.attributes = params
                }
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            @Suppress("DEPRECATION")
            val display = windowManager.defaultDisplay
            val modes = display.supportedModes
            val highestMode = modes.maxByOrNull { it.refreshRate }
            if (highestMode != null) {
                val params = window.attributes
                params.preferredDisplayModeId = highestMode.modeId
                window.attributes = params
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_PROXY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSystemProxy" -> result.success(querySystemProxy())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, KEEP_ALIVE_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    handleKeepAliveMethod(call, result)
                } catch (t: Throwable) {
                    result.error("keep_alive_error", t.message, null)
                }
            }
    }

    private fun querySystemProxy(): Map<String, Any?> {
        val fromConnectivity = queryConnectivityProxy()
        if (fromConnectivity != null) return fromConnectivity
        return querySystemPropertyProxy()
    }

    private fun queryConnectivityProxy(): Map<String, Any?>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return null
        }

        return try {
            val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return null
            val info = manager.defaultProxy ?: return null

            val host = info.host?.trim().orEmpty()
            val port = info.port
            val exclusionList = info.exclusionList?.joinToString(",") ?: ""
            val pacUrl = info.pacFileUrl?.toString().orEmpty()

            val enabled = host.isNotEmpty() && port > 0
            mapOf(
                "enabled" to enabled,
                "host" to if (host.isNotEmpty()) host else null,
                "port" to if (port > 0) port else null,
                "exclusionList" to exclusionList,
                "pacUrl" to pacUrl,
            )
        } catch (_: Throwable) {
            null
        }
    }

    private fun querySystemPropertyProxy(): Map<String, Any?> {
        val host = (System.getProperty("http.proxyHost")
            ?: System.getProperty("https.proxyHost")
            ?: "").trim()

        val portString = (System.getProperty("http.proxyPort")
            ?: System.getProperty("https.proxyPort")
            ?: "").trim()
        val port = portString.toIntOrNull()

        val exclusionList = (System.getProperty("http.nonProxyHosts")
            ?: System.getProperty("https.nonProxyHosts")
            ?: "").trim()

        val enabled = host.isNotEmpty() && (port ?: -1) > 0
        return mapOf(
            "enabled" to enabled,
            "host" to if (host.isNotEmpty()) host else null,
            "port" to port,
            "exclusionList" to exclusionList,
            "pacUrl" to "",
        )
    }

    private fun handleKeepAliveMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getStatus" -> result.success(buildKeepAliveStatus())
            "setGuardEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") == true
                KeepAliveConfig.setGuardEnabled(this, enabled)
                if (enabled) {
                    PersistentGuardService.start(this)
                } else {
                    PersistentGuardService.stop(this)
                }
                result.success(buildKeepAliveStatus())
            }
            "startGuardService" -> {
                PersistentGuardService.start(this)
                result.success(buildKeepAliveStatus())
            }
            "stopGuardService" -> {
                KeepAliveConfig.setGuardEnabled(this, false)
                PersistentGuardService.stop(this)
                result.success(buildKeepAliveStatus())
            }
            "requestIgnoreBatteryOptimizations" -> {
                result.success(requestIgnoreBatteryOptimizations())
            }
            "openBatteryOptimizationSettings" -> {
                result.success(openBatteryOptimizationSettings())
            }
            "openAutoStartSettings" -> {
                result.success(openAutoStartSettings())
            }
            "openBackgroundProtectionSettings" -> {
                result.success(openBackgroundProtectionSettings())
            }
            "openExactAlarmSettings" -> {
                result.success(openExactAlarmSettings())
            }
            else -> result.notImplemented()
        }
    }

    private fun buildKeepAliveStatus(): Map<String, Any?> {
        return mapOf(
            "guardEnabled" to KeepAliveConfig.isGuardEnabled(this),
            "serviceRunning" to PersistentGuardService.isRunning(this),
            "batteryOptimizationIgnored" to isBatteryOptimizationIgnored(),
            "canScheduleExactAlarms" to canScheduleExactAlarms(),
            "notificationsEnabled" to areNotificationsEnabled(),
            "manufacturer" to Build.MANUFACTURER,
            "brand" to Build.BRAND,
            "model" to Build.MODEL,
        )
    }

    private fun isBatteryOptimizationIgnored(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return true
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun canScheduleExactAlarms(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val manager = getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return false
        return manager.canScheduleExactAlarms()
    }

    private fun areNotificationsEnabled(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        return NotificationManagerCompat.from(this).areNotificationsEnabled()
    }

    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        if (isBatteryOptimizationIgnored()) return true
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:$packageName")
        }
        return launchIntent(intent)
    }

    private fun openBatteryOptimizationSettings(): Boolean {
        return launchIntent(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
    }

    private fun openAutoStartSettings(): Boolean {
        val manufacturer = Build.MANUFACTURER.lowercase()
        val candidates = mutableListOf<Intent>()

        if (manufacturer.contains("xiaomi")) {
            candidates += Intent().apply {
                component = ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity"
                )
            }
        }

        candidates += Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:$packageName")
        }

        return launchFirstAvailable(candidates)
    }

    private fun openBackgroundProtectionSettings(): Boolean {
        val manufacturer = Build.MANUFACTURER.lowercase()
        val appLabel = applicationInfo.loadLabel(packageManager).toString()
        val candidates = mutableListOf<Intent>()

        if (manufacturer.contains("xiaomi")) {
            candidates += Intent().apply {
                component = ComponentName(
                    "com.miui.powerkeeper",
                    "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"
                )
                putExtra("package_name", packageName)
                putExtra("package_label", appLabel)
            }
            candidates += Intent().apply {
                component = ComponentName(
                    "com.miui.powerkeeper",
                    "com.miui.powerkeeper.ui.HiddenAppsContainerManagementActivity"
                )
            }
        }

        candidates += Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:$packageName")
        }

        return launchFirstAvailable(candidates)
    }

    private fun openExactAlarmSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return false
        }
        val candidates = mutableListOf<Intent>()
        candidates += Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
            data = Uri.parse("package:$packageName")
        }
        candidates += Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:$packageName")
        }
        return launchFirstAvailable(candidates)
    }

    private fun launchFirstAvailable(candidates: List<Intent>): Boolean {
        for (intent in candidates) {
            if (launchIntent(intent)) {
                return true
            }
        }
        return false
    }

    private fun launchIntent(intent: Intent): Boolean {
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (_: Throwable) {
            false
        }
    }
}
