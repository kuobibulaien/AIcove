package com.example.aicove_flutter

import android.app.AlarmManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootCompletedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                ProactiveAlarmScheduler.restorePersistedAlarms(context.applicationContext)
                if (KeepAliveConfig.isGuardEnabled(context)) {
                    PersistentGuardService.start(context)
                }
            }
            AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED -> {
                ProactiveAlarmScheduler.restorePersistedAlarms(context.applicationContext)
            }
        }
    }
}
