package com.example.aicove_flutter

import android.content.Context
import android.Manifest
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object KeepAliveConfig {
    private const val PREFS_NAME = "aicove_keep_alive"
    private const val KEY_GUARD_ENABLED = "guard_enabled"

    fun isGuardEnabled(context: Context): Boolean {
        return prefs(context).getBoolean(KEY_GUARD_ENABLED, false)
    }

    fun setGuardEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_GUARD_ENABLED, enabled).apply()
    }

    const val CHANNEL = "com.example.aicove_flutter/keep_alive"

    data class Alarm(val fireAtMillis: Long, val exact: Boolean)

    fun readAlarm(context: Context, slot: String): Alarm? {
        val prefs = prefs(context)
        if (!prefs.contains("alarm_${slot}_time")) return null
        return Alarm(prefs.getLong("alarm_${slot}_time", 0), prefs.getBoolean("alarm_${slot}_exact", false))
    }

    fun saveAlarm(context: Context, slot: String, alarm: Alarm?) {
        val edit = prefs(context).edit()
        if (alarm == null) {
            edit.remove("alarm_${slot}_time").remove("alarm_${slot}_exact")
        } else {
            edit.putLong("alarm_${slot}_time", alarm.fireAtMillis)
                .putBoolean("alarm_${slot}_exact", alarm.exact)
        }
        // Scheduling and receiver restoration must observe the same durable state.
        check(edit.commit()) { "Unable to persist proactive alarm" }
    }

    fun clearProactiveAlarm(context: Context, slot: String) {
        saveAlarm(context, slot, null)
    }

    fun createChannel(
        context: Context,
        messenger: BinaryMessenger,
        onHeadlessComplete: (() -> Unit)? = null,
    ): MethodChannel {
        val handler = KeepAliveMethodHandler(context.applicationContext, onHeadlessComplete)
        return MethodChannel(messenger, CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                try {
                    handler.handle(call, result)
                } catch (t: Throwable) {
                    result.error("keep_alive_error", t.message, null)
                }
            }
        }
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
}

private class KeepAliveMethodHandler(
    private val context: Context,
    private val onHeadlessComplete: (() -> Unit)?,
) {
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "scheduleProactiveAlarm" -> {
                val slot = call.argument<String>("slot")
                    ?: return result.error("bad_args", "slot", null)
                val fireAt = call.argument<Number>("fireAtMillis")?.toLong()
                    ?: return result.error("bad_args", "fireAtMillis", null)
                ProactiveAlarmScheduler.schedule(context, slot, fireAt, call.argument<Boolean>("exact") == true)
                result.success(null)
            }
            "cancelProactiveAlarm" -> {
                val slot = call.argument<String>("slot")
                    ?: return result.error("bad_args", "slot", null)
                ProactiveAlarmScheduler.cancel(context, slot)
                result.success(null)
            }
            "consumePendingAlarmSlots" -> result.success(ProactiveAlarmScheduler.consumePendingSlots())
            "completeHeadlessAlarmRun" -> {
                result.success(null)
                onHeadlessComplete?.invoke()
            }
            "getStatus" -> result.success(buildKeepAliveStatus())
            "setGuardEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") == true
                if (enabled) {
                    KeepAliveConfig.setGuardEnabled(context, true)
                    val started = PersistentGuardService.start(context)
                    if (!started) {
                        KeepAliveConfig.setGuardEnabled(context, false)
                    }
                } else {
                    KeepAliveConfig.setGuardEnabled(context, false)
                    PersistentGuardService.stopIfIdle(context)
                }
                result.success(buildKeepAliveStatus())
            }
            "startGuardService" -> {
                KeepAliveConfig.setGuardEnabled(context, true)
                val started = PersistentGuardService.start(context)
                if (!started) {
                    KeepAliveConfig.setGuardEnabled(context, false)
                }
                result.success(buildKeepAliveStatus())
            }
            "stopGuardService" -> {
                KeepAliveConfig.setGuardEnabled(context, false)
                PersistentGuardService.stopIfIdle(context)
                result.success(buildKeepAliveStatus())
            }
            "setGenerationActive" -> {
                val active = call.argument<Boolean>("active") == true
                val changed = PersistentGuardService.setGenerationActive(context, active)
                if (changed) {
                    result.success(null)
                } else {
                    result.error(
                        "generation_guard_start_failed",
                        PersistentGuardService.getLastStartError()
                            ?: "Unable to start generation guard service",
                        null,
                    )
                }
            }
            "setWebAppActive" -> {
                val active = call.argument<Boolean>("active") == true
                val changed = PersistentGuardService.setWebAppActive(context, active)
                if (changed) {
                    result.success(null)
                } else {
                    result.error(
                        "webapp_guard_start_failed",
                        PersistentGuardService.getLastStartError()
                            ?: "Unable to start web app guard service",
                        null,
                    )
                }
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
            "openNotificationSettings" -> {
                result.success(openNotificationSettings())
            }
            "openExactAlarmSettings" -> {
                result.success(openExactAlarmSettings())
            }
            else -> result.notImplemented()
        }
    }

    private fun buildKeepAliveStatus(): Map<String, Any?> {
        val notificationPermissionGranted = hasNotificationPermission()
        val notificationsEnabled = areNotificationsEnabled()
        val guardNotificationChannelEnabled = isGuardNotificationChannelEnabled()
        val notificationVisibleInDrawer = notificationPermissionGranted &&
            notificationsEnabled &&
            guardNotificationChannelEnabled

        return mapOf(
            "guardEnabled" to KeepAliveConfig.isGuardEnabled(context),
            "generationActive" to PersistentGuardService.isGenerationActive(),
            "webAppActive" to PersistentGuardService.isWebAppActive(),
            "serviceRunning" to PersistentGuardService.isForegroundActive(),
            "generationWakeLockHeld" to PersistentGuardService.isGenerationWakeLockHeld(),
            "batteryOptimizationIgnored" to isBatteryOptimizationIgnored(),
            "canScheduleExactAlarms" to canScheduleExactAlarms(),
            "notificationPermissionGranted" to notificationPermissionGranted,
            "notificationsEnabled" to notificationsEnabled,
            "guardNotificationChannelEnabled" to guardNotificationChannelEnabled,
            "notificationVisibleInDrawer" to notificationVisibleInDrawer,
            "lastStartError" to PersistentGuardService.getLastStartError(),
            "manufacturer" to Build.MANUFACTURER,
            "brand" to Build.BRAND,
            "model" to Build.MODEL,
        )
    }

    private fun isBatteryOptimizationIgnored(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return true
        return pm.isIgnoringBatteryOptimizations(context.packageName)
    }

    private fun canScheduleExactAlarms(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val manager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return false
        return manager.canScheduleExactAlarms()
    }

    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return true
        }
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun areNotificationsEnabled(): Boolean {
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    private fun isGuardNotificationChannelEnabled(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return true
        }
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return false
        val channel = manager.getNotificationChannel(PersistentGuardService.CHANNEL_ID)
            ?: return true
        return channel.importance != NotificationManager.IMPORTANCE_NONE
    }

    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        if (isBatteryOptimizationIgnored()) return true
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:${context.packageName}")
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
            data = Uri.parse("package:${context.packageName}")
        }

        return launchFirstAvailable(candidates)
    }

    private fun openBackgroundProtectionSettings(): Boolean {
        val manufacturer = Build.MANUFACTURER.lowercase()
        val appLabel = context.applicationInfo.loadLabel(context.packageManager).toString()
        val candidates = mutableListOf<Intent>()

        if (manufacturer.contains("xiaomi")) {
            candidates += Intent().apply {
                component = ComponentName(
                    "com.miui.powerkeeper",
                    "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"
                )
                putExtra("package_name", context.packageName)
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
            data = Uri.parse("package:${context.packageName}")
        }

        return launchFirstAvailable(candidates)
    }

    private fun openNotificationSettings(): Boolean {
        val candidates = mutableListOf<Intent>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            candidates += Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                putExtra(Settings.EXTRA_CHANNEL_ID, PersistentGuardService.CHANNEL_ID)
            }
            candidates += Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            }
        }

        candidates += Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:${context.packageName}")
        }

        return launchFirstAvailable(candidates)
    }

    private fun openExactAlarmSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return false
        }
        val candidates = mutableListOf<Intent>()
        candidates += Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
            data = Uri.parse("package:${context.packageName}")
        }
        candidates += Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:${context.packageName}")
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
            context.startActivity(intent)
            true
        } catch (_: Throwable) {
            false
        }
    }
}
