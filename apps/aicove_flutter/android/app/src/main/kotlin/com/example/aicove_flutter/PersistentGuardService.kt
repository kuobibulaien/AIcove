package com.example.aicove_flutter

import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat

class PersistentGuardService : Service() {
    companion object {
        const val CHANNEL_ID = "aicove_guard_channel"
        const val NOTIFICATION_ID = 7101
        private const val ACTION_STOP_GUARD =
            "com.example.aicove_flutter.action.STOP_GUARD"
        private const val GENERATION_WAKE_LOCK_TIMEOUT_MS = 30 * 60 * 1000L

        @Volatile
        private var running: Boolean = false

        @Volatile
        private var foregroundActive: Boolean = false

        @Volatile
        private var lastStartError: String? = null

        @Volatile
        private var generationActive: Boolean = false

        @Volatile
        private var instance: PersistentGuardService? = null

        fun start(context: Context): Boolean {
            lastStartError = null
            return try {
                val intent = Intent(context, PersistentGuardService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                true
            } catch (t: Throwable) {
                foregroundActive = false
                running = false
                lastStartError = t.readableMessage()
                false
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, PersistentGuardService::class.java))
        }

        fun stopIfIdle(context: Context) {
            if (generationActive) {
                instance?.refreshForegroundState()
                return
            }
            stop(context)
        }

        fun setGenerationActive(context: Context, active: Boolean): Boolean {
            generationActive = active
            if (active) {
                val started = start(context)
                if (!started) {
                    generationActive = false
                }
                return started
            }

            instance?.refreshForegroundState()
            if (!KeepAliveConfig.isGuardEnabled(context)) {
                stop(context)
            }
            return true
        }

        fun isForegroundActive(): Boolean = foregroundActive

        fun isGenerationActive(): Boolean = generationActive

        fun getLastStartError(): String? = lastStartError

        fun isRunning(context: Context): Boolean {
            if (foregroundActive) return true

            val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                ?: return false
            @Suppress("DEPRECATION")
            return manager.getRunningServices(Int.MAX_VALUE).any {
                it.service.className == PersistentGuardService::class.java.name
            }
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var generationWakeLock: PowerManager.WakeLock? = null
    private val generationTimeoutRunnable = Runnable {
        generationActive = false
        refreshForegroundState()
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        foregroundActive = false
        running = false
        ensureNotificationChannel()
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(generationTimeoutRunnable)
        releaseGenerationWakeLock()
        instance = null
        running = false
        foregroundActive = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP_GUARD) {
            KeepAliveConfig.setGuardEnabled(this, false)
            lastStartError = null
        }
        return refreshForegroundState()
    }

    private fun refreshForegroundState(): Int {
        val persistentGuardEnabled = KeepAliveConfig.isGuardEnabled(this)
        if (!persistentGuardEnabled && !generationActive) {
            mainHandler.removeCallbacks(generationTimeoutRunnable)
            releaseGenerationWakeLock()
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        return try {
            startForegroundCompat()
            updateGenerationWakeLock()
            running = true
            foregroundActive = true
            lastStartError = null
            if (persistentGuardEnabled) START_STICKY else START_NOT_STICKY
        } catch (t: Throwable) {
            KeepAliveConfig.setGuardEnabled(this, false)
            generationActive = false
            mainHandler.removeCallbacks(generationTimeoutRunnable)
            releaseGenerationWakeLock()
            running = false
            foregroundActive = false
            lastStartError = t.readableMessage()
            stopSelf()
            START_NOT_STICKY
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "AI 守护模式",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "保持 AIcove 主动回复与聊天生成在后台尽量稳定运行"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification() = NotificationCompat.Builder(this, CHANNEL_ID)
        .setContentTitle("AI 守护中")
        .setContentText(
            if (generationActive) {
                "正在后台生成回复，完成后会自动释放临时守护。"
            } else {
                "主动回复守护模式已开启，点击可返回应用。"
            },
        )
        .setSmallIcon(android.R.drawable.ic_dialog_info)
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setCategory(NotificationCompat.CATEGORY_SERVICE)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .setContentIntent(buildOpenAppPendingIntent())
        .addAction(
            0,
            "停止长期守护",
            buildStopPendingIntent(),
        )
        .build()

    private fun buildOpenAppPendingIntent(): PendingIntent {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or pendingIntentImmutableFlag(),
        )
    }

    private fun buildStopPendingIntent(): PendingIntent {
        val intent = Intent(this, PersistentGuardService::class.java).apply {
            action = ACTION_STOP_GUARD
        }
        return PendingIntent.getService(
            this,
            1,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or pendingIntentImmutableFlag(),
        )
    }

    private fun stopForegroundCompat() {
        foregroundActive = false
        running = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        NotificationManagerCompat.from(this).cancel(NOTIFICATION_ID)
    }

    private fun startForegroundCompat() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
            return
        }
        startForeground(NOTIFICATION_ID, notification)
    }

    private fun updateGenerationWakeLock() {
        if (!generationActive) {
            mainHandler.removeCallbacks(generationTimeoutRunnable)
            releaseGenerationWakeLock()
            return
        }

        mainHandler.removeCallbacks(generationTimeoutRunnable)
        mainHandler.postDelayed(
            generationTimeoutRunnable,
            GENERATION_WAKE_LOCK_TIMEOUT_MS,
        )
        val current = generationWakeLock
        if (current?.isHeld == true) return
        val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        generationWakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:chat-generation",
        ).apply {
            setReferenceCounted(false)
            acquire(GENERATION_WAKE_LOCK_TIMEOUT_MS)
        }
    }

    private fun releaseGenerationWakeLock() {
        val current = generationWakeLock
        generationWakeLock = null
        if (current?.isHeld == true) {
            current.release()
        }
    }

    private fun pendingIntentImmutableFlag(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE
        } else {
            0
        }
    }
}

private fun Throwable.readableMessage(): String {
    val detail = message?.trim().orEmpty()
    return if (detail.isNotEmpty()) detail else javaClass.simpleName
}
