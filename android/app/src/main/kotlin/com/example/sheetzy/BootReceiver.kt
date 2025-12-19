package com.example.sheetzy

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (Intent.ACTION_BOOT_COMPLETED == intent.action) {
            Log.d("BootReceiver", "Boot completed, WorkManager tasks will be re-registered on next app launch")
            // WorkManager tasks persist across reboots, but we ensure they're registered
            // by having the app re-register them on resume (handled in Flutter lifecycle)
            // This receiver ensures the app knows to re-register when it next launches
        }
    }
}
