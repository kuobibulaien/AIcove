package com.example.aicove_flutter

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** AlarmManager and Flutter engine state are owned exclusively by the Android main thread. */
object ProactiveAlarmScheduler {
    private const val TAG = "ProactiveAlarm"
    const val ACTION_FIRE = "com.example.aicove_flutter.PROACTIVE_ALARM"
    const val EXTRA_SLOT = "slot"
    const val EXTRA_FIRE_AT = "fireAtMillis"
    private const val RUN_TIMEOUT_MS = 180_000L
    private const val ENTRYPOINT_LIBRARY =
        "package:aicove_flutter/src/features/auto_reply/data/background_service.dart"
    private val slots = mapOf("analyzer" to 7201, "trigger" to 7202)
    private val handler = Handler(Looper.getMainLooper())
    private var mainChannel: MethodChannel? = null
    private var headlessEngine: FlutterEngine? = null
    private var headlessChannel: MethodChannel? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var timeout: Runnable? = null
    private var deliveryLease: Any? = null
    private val pendingSlots = linkedSetOf<String>()
    private val mainRuns = mutableMapOf<String, Any>()

    private fun checkMainThread() {
        check(Looper.myLooper() == Looper.getMainLooper())
    }

    fun schedule(context: Context, slot: String, fireAtMillis: Long, exact: Boolean) {
        checkMainThread()
        require(slots.containsKey(slot)) { "Unknown proactive alarm slot: $slot" }
        require(fireAtMillis > 0) { "fireAtMillis must be positive" }
        val alarm = KeepAliveConfig.Alarm(maxOf(fireAtMillis, System.currentTimeMillis() + 1_000L), exact)
        KeepAliveConfig.saveAlarm(context, slot, alarm)
        install(context, slot, alarm)
    }

    private fun install(context: Context, slot: String, alarm: KeepAliveConfig.Alarm) {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = PendingIntent.getBroadcast(
            context, slots.getValue(slot),
            Intent(context, ProactiveAlarmReceiver::class.java).apply {
                action = ACTION_FIRE
                data = alarmUri(slot)
                putExtra(EXTRA_SLOT, slot)
                putExtra(EXTRA_FIRE_AT, alarm.fireAtMillis)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val triggerAt = alarm.fireAtMillis
        if (alarm.exact && (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || manager.canScheduleExactAlarms())) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, intent)
                } else {
                    manager.setExact(AlarmManager.RTC_WAKEUP, triggerAt, intent)
                }
                return
            } catch (e: SecurityException) {
                // Permission can be revoked between checking and scheduling.
                Log.w(TAG, "Exact permission unavailable; scheduling inexact $slot", e)
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, intent)
        } else {
            manager.set(AlarmManager.RTC_WAKEUP, triggerAt, intent)
        }
    }

    fun cancel(context: Context, slot: String) {
        checkMainThread()
        require(slots.containsKey(slot)) { "Unknown proactive alarm slot: $slot" }
        KeepAliveConfig.clearProactiveAlarm(context, slot)
        val intent = PendingIntent.getBroadcast(
            context, slots.getValue(slot),
            Intent(context, ProactiveAlarmReceiver::class.java).setAction(ACTION_FIRE).setData(alarmUri(slot)),
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
        )
        if (intent != null) {
            (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(intent)
            intent.cancel()
        }
    }

    private fun alarmUri(slot: String): Uri = Uri.parse("aicove://proactive-alarm/$slot")

    fun restorePersistedAlarms(context: Context) {
        checkMainThread()
        slots.keys.forEach { slot ->
            KeepAliveConfig.readAlarm(context, slot)?.let { alarm ->
                try {
                    schedule(context, slot, alarm.fireAtMillis, alarm.exact)
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to restore $slot alarm", e)
                }
            }
        }
    }

    fun attachMainChannel(context: Context, channel: MethodChannel) {
        checkMainThread()
        mainChannel = channel
        dispatchPending(context.applicationContext)
    }

    fun detachMainChannel(context: Context, channel: MethodChannel) {
        checkMainThread()
        if (mainChannel !== channel) return
        mainChannel = null
        pendingSlots.addAll(mainRuns.keys)
        mainRuns.clear()
        if (pendingSlots.isNotEmpty()) startHeadless(context.applicationContext)
    }

    fun onAlarmFired(context: Context, slot: String, fireAtMillis: Long) {
        checkMainThread()
        ensureDeliveryLease(context.applicationContext)
        try {
            if (!slots.containsKey(slot)) return
            // Ignore canceled or replaced broadcasts already queued by AlarmManager.
            if (KeepAliveConfig.readAlarm(context, slot)?.fireAtMillis != fireAtMillis) return
            KeepAliveConfig.clearProactiveAlarm(context, slot)
            pendingSlots.add(slot)
            dispatchPending(context.applicationContext)
        } finally {
            releaseIfIdle()
        }
    }

    private fun dispatchPending(context: Context) {
        if (pendingSlots.isEmpty() || headlessEngine != null) return
        val channel = mainChannel
        if (channel == null) {
            startHeadless(context)
            return
        }
        pendingSlots.toList().forEach { slot ->
            if (headlessEngine != null || !pendingSlots.contains(slot) || mainRuns.containsKey(slot)) return@forEach
            pendingSlots.remove(slot)
            val token = Any()
            mainRuns[slot] = token
            fun finish(fallback: Boolean) {
                if (mainRuns[slot] !== token) return
                mainRuns.remove(slot)
                if (fallback) {
                    pendingSlots.add(slot)
                    startHeadless(context)
                } else {
                    dispatchPending(context)
                }
                releaseIfIdle()
            }
            try {
                channel.invokeMethod("onProactiveAlarmFired", mapOf("slot" to slot), object : MethodChannel.Result {
                    override fun success(result: Any?) = finish(false)
                    override fun error(code: String, message: String?, details: Any?) = finish(false)
                    override fun notImplemented() = finish(true)
                })
            } catch (e: Exception) {
                Log.w(TAG, "Main engine alarm delivery failed", e)
                finish(true)
            }
        }
    }

    fun consumePendingSlots(): List<String> {
        checkMainThread()
        return pendingSlots.toList().also { pendingSlots.clear() }
    }

    private fun startHeadless(context: Context) {
        if (headlessEngine != null || pendingSlots.isEmpty()) return
        ensureDeliveryLease(context)
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(context)
            loader.ensureInitializationComplete(context, null)
            val engine = FlutterEngine(context)
            headlessEngine = engine
            headlessChannel = KeepAliveConfig.createChannel(context, engine.dartExecutor.binaryMessenger) {
                // Dart may already have closed its resources after its last empty consume.
                // Always retire this engine; arrivals in that gap start a fresh run.
                handler.post {
                    if (headlessEngine === engine) {
                        stopHeadless()
                        if (pendingSlots.isNotEmpty()) startHeadless(context)
                    }
                }
            }
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), ENTRYPOINT_LIBRARY, "proactiveAlarmEntrypoint"),
            )
        } catch (e: Exception) {
            Log.e(TAG, "Unable to start headless proactive alarm; abandoning slots $pendingSlots", e)
            pendingSlots.clear()
            stopHeadless()
        }
    }

    private fun ensureDeliveryLease(context: Context) {
        if (deliveryLease != null) return
        val token = Any()
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = power.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK, "${context.packageName}:proactive-alarm",
        ).also {
            it.setReferenceCounted(false)
            it.acquire(RUN_TIMEOUT_MS)
        }
        deliveryLease = token
        timeout = Runnable {
            if (deliveryLease === token) {
                Log.w(TAG, "Alarm delivery exceeded ${RUN_TIMEOUT_MS}ms; abandoning pending $pendingSlots and main ${mainRuns.keys}")
                // Late callbacks carry old tokens and cannot clear a subsequent delivery.
                pendingSlots.clear()
                mainRuns.clear()
                stopHeadless()
                releaseIfIdle()
            }
        }.also { handler.postDelayed(it, RUN_TIMEOUT_MS) }
    }

    private fun releaseIfIdle() {
        if (headlessEngine != null || mainRuns.isNotEmpty() || pendingSlots.isNotEmpty()) return
        timeout?.let { handler.removeCallbacks(it) }
        timeout = null
        deliveryLease = null
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } finally {
            wakeLock = null
        }
    }

    private fun stopHeadless() {
        headlessChannel?.setMethodCallHandler(null)
        headlessChannel = null
        val engine = headlessEngine
        headlessEngine = null
        try {
            engine?.destroy()
        } catch (e: Exception) {
            Log.w(TAG, "Unable to destroy headless engine", e)
        } finally {
            releaseIfIdle()
        }
    }
}
