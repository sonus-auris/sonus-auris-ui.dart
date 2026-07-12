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
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications (scheduled-recording consent prompts) uses
        // java.time APIs that require core library desugaring on older Android.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.ores.audio_dashcam"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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
            // Sign with the real release keystore when key.properties is present.
            // A release artifact must NEVER be silently debug-signed: Google Play
            // rejects debug-signed uploads, and an accidental upload would be signed
            // with the wrong (non-upload) key. So if key.properties is absent we FAIL
            // the release build — unless the developer explicitly opts into debug
            // signing for a local run (e.g. `flutter run --release`) by passing
            // `-Pallow_debug_signed_release=true` or setting
            // ALLOW_DEBUG_SIGNED_RELEASE=1. The store build scripts never set these.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                val allowDebugRelease =
                    (project.findProperty("allow_debug_signed_release") as String?)
                        ?.toBoolean() == true ||
                    System.getenv("ALLOW_DEBUG_SIGNED_RELEASE") == "1"
                if (!allowDebugRelease) {
                    throw GradleException(
                        "Release build requires android/key.properties (release signing). " +
                        "It is missing, so this build would be DEBUG-SIGNED and rejected by " +
                        "Google Play. Create it via scripts/release/android-generate-keystore.sh, " +
                        "or, for a local non-store `flutter run --release`, pass " +
                        "-Pallow_debug_signed_release=true (or ALLOW_DEBUG_SIGNED_RELEASE=1)."
                    )
                }
                signingConfigs.getByName("debug")
            }
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
