package com.ores.audio_dashcam

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        RecordingScheduleBridge.bind(this, flutterEngine.dartExecutor.binaryMessenger)
        AmbientTriggerBridge.bind(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        RecordingScheduleBridge.deliverBarrierIfNeeded(this, intent)
        AmbientTriggerBridge.deliverTriggerIfNeeded(this, intent)
    }

    override fun onResume() {
        super.onResume()
        RecordingScheduleBridge.deliverPendingBarrier(this)
        AmbientTriggerBridge.deliverPendingTrigger(this)
    }
}

object RecordingScheduleBridge {
    private const val channelName = "audio_dashcam/recording_schedule"
    private const val barrierAction = "com.ores.audio_dashcam.RECORDING_SCHEDULE_BARRIER"
    private const val barrierExtra = "recording_schedule_barrier"
    private const val prefsName = "recording_schedule"
    private const val pendingKey = "pending_barrier"
    private const val requestCode = 7107

    private var channel: MethodChannel? = null

    fun bind(context: Context, messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, channelName).also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "replaceSchedule" -> {
                        replaceSchedule(context, call.arguments)
                        result.success(null)
                    }
                    "clearSchedule" -> {
                        clearSchedule(context)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        deliverPendingBarrier(context)
    }

    fun deliverBarrierIfNeeded(context: Context, intent: Intent?) {
        if (intent?.getBooleanExtra(barrierExtra, false) == true) {
            deliverPendingBarrier(context)
        }
    }

    fun markPendingBarrier(context: Context) {
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(pendingKey, true)
            .apply()
    }

    fun deliverPendingBarrier(context: Context) {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(pendingKey, false)) {
            return
        }
        val activeChannel = channel ?: return
        prefs.edit().putBoolean(pendingKey, false).apply()
        Handler(Looper.getMainLooper()).post {
            activeChannel.invokeMethod("barrier", null)
        }
    }

    private fun replaceSchedule(context: Context, arguments: Any?) {
        val args = arguments as? Map<*, *> ?: return
        val triggerAtMillis = (args["nextBarrierEpochMillis"] as? Number)?.toLong()
        if (triggerAtMillis == null) {
            clearSchedule(context)
            return
        }
        scheduleBarrier(context, triggerAtMillis)
    }

    private fun scheduleBarrier(context: Context, triggerAtMillis: Long) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pendingIntent = barrierPendingIntent(context)
        alarmManager.cancel(pendingIntent)
        if (triggerAtMillis <= System.currentTimeMillis()) {
            markPendingBarrier(context)
            deliverPendingBarrier(context)
            return
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtMillis,
                    pendingIntent,
                )
            } else {
                alarmManager.setExact(AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent)
            }
        } catch (_: SecurityException) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtMillis,
                    pendingIntent,
                )
            } else {
                alarmManager.set(AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent)
            }
        }
    }

    private fun clearSchedule(context: Context) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.cancel(barrierPendingIntent(context))
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
            .edit()
            .remove(pendingKey)
            .apply()
    }

    private fun barrierPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, RecordingScheduleReceiver::class.java).apply {
            action = barrierAction
        }
        return PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun launchForBarrier(context: Context) {
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: return
        launchIntent
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(barrierExtra, true)
        context.startActivity(launchIntent)
    }
}

class RecordingScheduleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "com.ores.audio_dashcam.RECORDING_SCHEDULE_BARRIER") {
            return
        }
        RecordingScheduleBridge.markPendingBarrier(context)
        RecordingScheduleBridge.deliverPendingBarrier(context)
        RecordingScheduleBridge.launchForBarrier(context)
    }
}

object AmbientTriggerBridge {
    private const val channelName = "audio_dashcam/ambient_triggers"
    private const val triggerExtra = "ambient_recording_trigger"
    private const val prefsName = "ambient_recording_triggers"
    private const val pendingKey = "pending"
    private const val kindKey = "kind"
    private const val labelKey = "label"
    private const val detailKey = "detail"
    private const val occurredAtKey = "occurred_at"

    private var channel: MethodChannel? = null

    fun bind(context: Context, messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, channelName).also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "startMonitoring" -> {
                        deliverPendingTrigger(context)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        deliverPendingTrigger(context)
    }

    fun deliverTriggerIfNeeded(context: Context, intent: Intent?) {
        if (intent?.getBooleanExtra(triggerExtra, false) == true) {
            deliverPendingTrigger(context)
        }
    }

    fun markPendingTrigger(
        context: Context,
        kind: String,
        label: String,
        detail: String,
    ) {
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(pendingKey, true)
            .putString(kindKey, kind)
            .putString(labelKey, label)
            .putString(detailKey, detail)
            .putLong(occurredAtKey, System.currentTimeMillis())
            .apply()
    }

    fun deliverPendingTrigger(context: Context) {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(pendingKey, false)) {
            return
        }
        val activeChannel = channel ?: return
        val occurredAt = prefs.getLong(occurredAtKey, System.currentTimeMillis())
        val payload = mapOf(
            "kind" to (prefs.getString(kindKey, "ambient") ?: "ambient"),
            "label" to (prefs.getString(labelKey, "Device event") ?: "Device event"),
            "detail" to (prefs.getString(detailKey, "") ?: ""),
            "occurredAtMillis" to occurredAt,
        )
        prefs.edit().putBoolean(pendingKey, false).apply()
        Handler(Looper.getMainLooper()).post {
            activeChannel.invokeMethod("trigger", payload)
        }
    }

    fun launchForTrigger(context: Context) {
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: return
        launchIntent
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(triggerExtra, true)
        context.startActivity(launchIntent)
    }
}

class AmbientTriggerReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        val event = when (action) {
            "android.bluetooth.device.action.ACL_CONNECTED" ->
                Triple("bluetooth", "Bluetooth connected", "External Bluetooth device connected")
            "android.bluetooth.device.action.ACL_DISCONNECTED" ->
                Triple("bluetooth", "Bluetooth disconnected", "External Bluetooth device disconnected")
            ConnectivityManager.CONNECTIVITY_ACTION,
            WifiManager.NETWORK_STATE_CHANGED_ACTION ->
                Triple("connectivity", "Network changed", "Wi-Fi or cellular connection changed")
            else -> return
        }
        AmbientTriggerBridge.markPendingTrigger(
            context,
            kind = event.first,
            label = event.second,
            detail = event.third,
        )
        AmbientTriggerBridge.deliverPendingTrigger(context)
        AmbientTriggerBridge.launchForTrigger(context)
    }
}
