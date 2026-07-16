# TFLite (tflite_flutter): the runtime references the optional GPU delegate
# classes reflectively; keep them and silence the missing-class warning for
# the Options inner class that only exists in the gpu-api artifact.
-keep class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.gpu.GpuDelegateFactory$Options
