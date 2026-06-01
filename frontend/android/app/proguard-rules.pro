# R8/ProGuard keep rules for the on-device ML stack.
#
# tflite_flutter references TensorFlow Lite's optional GPU delegate classes, but
# we run CPU-only (no GPU delegate bundled), so R8 reports them as missing and
# fails the release build. Suppress those warnings and keep the TFLite classes.

-dontwarn org.tensorflow.lite.gpu.GpuDelegateFactory$Options$GpuBackend
-dontwarn org.tensorflow.lite.gpu.GpuDelegateFactory$Options
-dontwarn org.tensorflow.lite.gpu.**
-keep class org.tensorflow.lite.** { *; }

# onnxruntime (flutter_onnxruntime) — keep JNI-referenced classes intact.
-dontwarn ai.onnxruntime.**
-keep class ai.onnxruntime.** { *; }
