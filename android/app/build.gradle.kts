import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is driven by an untracked `android/key.properties` (already in
// android/.gitignore). When it is absent — local dev, CI without secrets — the
// release build falls back to the debug keystore so `flutter run --release` still
// works exactly as before. Provide key.properties (storeFile, storePassword,
// keyAlias, keyPassword) to ship a properly-signed, tamper-evident release.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.ores.audio_dashcam"
    // Pin the store contract instead of inheriting a moving Flutter default.
    // Google Play requires API 36 for new apps/updates starting 2026-08-31.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications (scheduled-recording consent prompts) uses
        // java.time APIs that require core library desugaring on older Android.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Permanent Play Store identity. Never change after the first upload.
        applicationId = "com.ores.audio_dashcam"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        jniLibs {
            // tflite_flutter bundles the TFLite GPU delegate (~3.4 MB/ABI).
            // Our models (Perch bird ID) run on CPU/XNNPack only — drop the
            // GPU .so to keep the store download small.
            excludes += "**/libtensorflowlite_gpu_jni.so"
        }
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Sign with the real release keystore when key.properties is present;
            // otherwise fall back to debug signing so config-time evaluation (which
            // happens for ALL builds, including debug) never fails. The guard below
            // is what actually blocks a *debug-signed release artifact* from being
            // produced — deferred to execution time so only release tasks are gated.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Keep rules for TFLite's reflective GPU-delegate references.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Required by isCoreLibraryDesugaringEnabled above.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}

// Guard: never ship a DEBUG-SIGNED release. Google Play rejects debug-signed
// uploads, and an accidental upload would be signed with the wrong (non-upload)
// key. If key.properties is missing and a release-assembling task is scheduled,
// fail — unless the developer explicitly opts in for a local, non-store build
// (`flutter run --release`) via -Pallow_debug_signed_release=true or
// ALLOW_DEBUG_SIGNED_RELEASE=1. The store scripts never set these, so a mis-keyed
// AAB/APK can never be produced by CI or `scripts/release/*`.
gradle.taskGraph.whenReady {
    val keystoreMissing = !rootProject.file("key.properties").exists()
    val allowDebugRelease =
        (project.findProperty("allow_debug_signed_release") as String?)?.toBoolean() == true ||
        System.getenv("ALLOW_DEBUG_SIGNED_RELEASE") == "1"
    if (keystoreMissing && !allowDebugRelease) {
        val releaseTask = allTasks.firstOrNull { t ->
            val n = t.name
            (n.contains("Release") && (n.startsWith("assemble") ||
                n.startsWith("bundle") || n.startsWith("package") || n.startsWith("sign")))
        }
        if (releaseTask != null) {
            throw GradleException(
                "Refusing to build a DEBUG-SIGNED release ('${releaseTask.path}'): " +
                "android/key.properties is missing. Create it via " +
                "scripts/release/android-generate-keystore.sh for a real signed build, " +
                "or, for a local non-store `flutter run --release`, pass " +
                "-Pallow_debug_signed_release=true (or ALLOW_DEBUG_SIGNED_RELEASE=1)."
            )
        }
    }
}
