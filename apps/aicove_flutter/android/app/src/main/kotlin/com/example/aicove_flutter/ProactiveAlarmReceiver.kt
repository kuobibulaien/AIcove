package com.example.aicove_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class ProactiveAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ProactiveAlarmScheduler.ACTION_FIRE) return
        val slot = intent.getStringExtra(ProactiveAlarmScheduler.EXTRA_SLOT) ?: return
        try {
            ProactiveAlarmScheduler.onAlarmFired(
                context.applicationContext,
                slot,
                intent.getLongExtra(ProactiveAlarmScheduler.EXTRA_FIRE_AT, 0),
            )
        } catch (e: Exception) {
            Log.e("ProactiveAlarm", "Unable to deliver $slot alarm", e)
        }
    }
}
