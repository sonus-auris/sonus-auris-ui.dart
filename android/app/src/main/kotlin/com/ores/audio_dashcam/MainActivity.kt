// Flutter host Activity; also serves the audio_dashcam/sleep_sensors method channel, sampling the accelerometer (motion) and light sensor for sleep sensing.
package com.ores.audio_dashcam

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.math.sqrt

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "audio_dashcam/sleep_sensors"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "sampleSleepSignals" -> {
                    val motion = call.argument<Boolean>("motion") ?: false
                    val ambientLight = call.argument<Boolean>("ambientLight") ?: false
                    sampleSleepSignals(motion, ambientLight, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun sampleSleepSignals(
        motion: Boolean,
        ambientLight: Boolean,
        result: MethodChannel.Result
    ) {
        val sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        val accelerometer = if (motion) {
            sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        } else {
            null
        }
        val light = if (ambientLight) {
            sensorManager.getDefaultSensor(Sensor.TYPE_LIGHT)
        } else {
            null
        }
        if (accelerometer == null && light == null) {
            result.success(
                mapOf(
                    "sampledAtMillis" to System.currentTimeMillis(),
                    "motionAvailable" to false,
                    "ambientLightAvailable" to false
                )
            )
            return
        }

        var lastAccelerationMagnitude: Double? = null
        var accelerationDeltaSum = 0.0
        var accelerationSamples = 0
        var lightSum = 0.0
        var lightSamples = 0
        var completed = false
        lateinit var listener: SensorEventListener
        listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                when (event.sensor.type) {
                    Sensor.TYPE_ACCELEROMETER -> {
                        val x = event.values[0].toDouble()
                        val y = event.values[1].toDouble()
                        val z = event.values[2].toDouble()
                        val magnitude = sqrt(
                            x * x +
                                y * y +
                                z * z
                        )
                        val last = lastAccelerationMagnitude
                        if (last != null) {
                            accelerationDeltaSum += abs(magnitude - last)
                            accelerationSamples += 1
                        }
                        lastAccelerationMagnitude = magnitude
                    }
                    Sensor.TYPE_LIGHT -> {
                        lightSum += event.values[0].toDouble()
                        lightSamples += 1
                    }
                }
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
        }

        accelerometer?.let {
            sensorManager.registerListener(listener, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
        light?.let {
            sensorManager.registerListener(listener, it, SensorManager.SENSOR_DELAY_NORMAL)
        }

        Handler(Looper.getMainLooper()).postDelayed({
            if (completed) {
                return@postDelayed
            }
            completed = true
            sensorManager.unregisterListener(listener)
            val averageDelta = if (accelerationSamples > 0) {
                accelerationDeltaSum / accelerationSamples
            } else {
                null
            }
            val stillness = averageDelta?.let {
                (1.0 - (it / 1.25)).coerceIn(0.0, 1.0)
            }
            val ambientLux = if (lightSamples > 0) {
                lightSum / lightSamples
            } else {
                null
            }
            result.success(
                mapOf(
                    "sampledAtMillis" to System.currentTimeMillis(),
                    "motionAvailable" to (accelerometer != null && stillness != null),
                    "motionStillnessScore" to stillness,
                    "ambientLightAvailable" to (light != null && ambientLux != null),
                    "ambientLux" to ambientLux
                )
            )
        }, 750L)
    }
}
