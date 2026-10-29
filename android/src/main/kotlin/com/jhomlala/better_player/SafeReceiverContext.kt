package com.jhomlala.better_player

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler

/**
 * ExoPlayer 2.17 [PlayerNotificationManager] calls [Context.registerReceiver] without
 * RECEIVER_EXPORTED / RECEIVER_NOT_EXPORTED. On Android 13+ (targetSdk 33+) that throws
 * SecurityException. Quanteec locks us to ExoPlayer 2.17, so wrap the context instead.
 *
 * Important: [PlayerNotificationManager.Builder] stores `context.applicationContext`, so
 * [getApplicationContext] must return this wrapper or the fix is stripped immediately.
 */
class SafeReceiverContext(base: Context) : ContextWrapper(base) {

    override fun getApplicationContext(): Context = this

    @SuppressLint("UnspecifiedRegisterReceiverFlag")
    override fun registerReceiver(receiver: BroadcastReceiver?, filter: IntentFilter?): Intent? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            super.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            super.registerReceiver(receiver, filter)
        }
    }

    @SuppressLint("UnspecifiedRegisterReceiverFlag")
    override fun registerReceiver(
        receiver: BroadcastReceiver?,
        filter: IntentFilter?,
        flags: Int
    ): Intent? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val safeFlags =
                if (flags and (Context.RECEIVER_EXPORTED or Context.RECEIVER_NOT_EXPORTED) == 0) {
                    flags or Context.RECEIVER_NOT_EXPORTED
                } else {
                    flags
                }
            super.registerReceiver(receiver, filter, safeFlags)
        } else {
            super.registerReceiver(receiver, filter, flags)
        }
    }

    @SuppressLint("UnspecifiedRegisterReceiverFlag")
    override fun registerReceiver(
        receiver: BroadcastReceiver?,
        filter: IntentFilter?,
        broadcastPermission: String?,
        scheduler: Handler?
    ): Intent? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            super.registerReceiver(
                receiver,
                filter,
                broadcastPermission,
                scheduler,
                Context.RECEIVER_NOT_EXPORTED
            )
        } else {
            @Suppress("DEPRECATION")
            super.registerReceiver(receiver, filter, broadcastPermission, scheduler)
        }
    }

    @SuppressLint("UnspecifiedRegisterReceiverFlag")
    override fun registerReceiver(
        receiver: BroadcastReceiver?,
        filter: IntentFilter?,
        broadcastPermission: String?,
        scheduler: Handler?,
        flags: Int
    ): Intent? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val safeFlags =
                if (flags and (Context.RECEIVER_EXPORTED or Context.RECEIVER_NOT_EXPORTED) == 0) {
                    flags or Context.RECEIVER_NOT_EXPORTED
                } else {
                    flags
                }
            super.registerReceiver(receiver, filter, broadcastPermission, scheduler, safeFlags)
        } else {
            super.registerReceiver(receiver, filter, broadcastPermission, scheduler, flags)
        }
    }
}
