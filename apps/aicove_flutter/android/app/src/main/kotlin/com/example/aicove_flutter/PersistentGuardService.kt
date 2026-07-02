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
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat

class PersistentGuardService : Service() {
    companion object {
        const val CHANNEL_ID = "aicove_guard_channel"
        const val NOTIFICATION_ID = 7101
        private const val ACTION_STOP_GUARD = "com.example.aicove_flutter.action.STOP_GUARD"

        @Volatile
        private var running: Boolean = false

        @Volatile
        private var foregroundActive: Boolean = false

        @Volatile
        private var lastStartError: String? = null

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

        fun isForegroundActive(): Boolean = foregroundActive

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

    override fun onCreate() {
        super.onCreate()
        foregroundActive = false
        running = false
        ensureNotificationChannel()
    }

    override fun onDestroy() {
        running = false
        foregroundActive = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP_GUARD) {
            KeepAliveConfig.setGuardEnabled(this, false)
            lastStartError = null
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        return try {
            startForegroundCompat()
            running = true
            foregroundActive = true
            lastStartError = null
            START_STICKY
        } catch (t: Throwable) {
            KeepAliveConfig.setGuardEnabled(this, false)
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
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "保持 AIcove 主动回复在后台尽量稳定运行"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification() = NotificationCompat.Builder(this, CHANNEL_ID)
        .setContentTitle("AI 守护中")
        .setContentText("主动回复守护模式已开启，点击可返回应用。")
        .setSmallIcon(android.R.drawable.ic_dialog_info)
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setCategory(NotificationCompat.CATEGORY_SERVICE)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .setContentIntent(buildOpenAppPendingIntent())
        .addAction(
            0,
            "停止守护",
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
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
            return
        }
        startForeground(NOTIFICATION_ID, notification)
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
