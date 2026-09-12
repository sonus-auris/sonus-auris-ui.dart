import java.io.File
import java.io.FileInputStream
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Properties
import org.gradle.api.GradleException

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

class ReleaseSigningMaterial(
    val keystore: File,
    val storePassword: String,
    val keyAlias: String,
    val keyPassword: String,
)

val keystorePropertiesFile = rootProject.file("key.properties")

fun requiredReleaseProperty(
    properties: Properties,
    name: String,
    trim: Boolean = false,
): String {
    val raw = properties.getProperty(name).orEmpty()
    if (raw.isBlank() || raw == "CHANGE_ME") {
        throw GradleException("DEN-2843: android/key.properties requires non-placeholder $name")
    }
    return if (trim) raw.trim() else raw
}

fun requiredReleaseEnvironment(name: String): String {
    val value = System.getenv(name)?.trim().orEmpty()
    if (value.isEmpty()) {
        throw GradleException("DEN-2843: Android release signing requires non-blank $name")
    }
    return value
}

fun normalizeSha256Fingerprint(value: String): String {
    val normalized = value.filter(Char::isLetterOrDigit).uppercase()
    if (!Regex("[0-9A-F]{64}").matches(normalized)) {
        throw GradleException(
            "DEN-2843: SONUS_ANDROID_UPLOAD_CERT_SHA256 must be a 64-digit SHA-256 fingerprint",
        )
    }
    return normalized
}

fun loadReleaseKeyStore(path: File, password: CharArray): KeyStore {
    val failures = mutableListOf<String>()
    for (type in listOf("PKCS12", "JKS")) {
        try {
            val keyStore = KeyStore.getInstance(type)
            FileInputStream(path).use { stream -> keyStore.load(stream, password) }
            return keyStore
        } catch (error: Exception) {
            failures += "$type:${error.javaClass.simpleName}"
        }
    }
    throw GradleException(
        "DEN-2843: release keystore is unreadable or its password is invalid (${failures.joinToString()})",
    )
}

fun certificateSha256(keyStore: KeyStore, alias: String): String {
    if (!keyStore.containsAlias(alias) || !keyStore.isKeyEntry(alias)) {
        throw GradleException("DEN-2843: release key alias is absent or is not a private-key entry")
    }
    val certificate = keyStore.getCertificate(alias)
        ?: throw GradleException("DEN-2843: release key alias has no certificate")
    if (certificate.toString().contains("CN=Android Debug", ignoreCase = true)) {
        throw GradleException("DEN-2843: the Android Debug certificate is forbidden for releases")
    }
    return MessageDigest.getInstance("SHA-256")
        .digest(certificate.encoded)
        .joinToString(separator = "") { byte ->
            (byte.toInt() and 0xff).toString(16).padStart(2, '0').uppercase()
        }
}

// Android Studio sync and ordinary debug/profile builds must not require
// production credentials. Every explicitly requested release task does.
val releaseTaskRequested = gradle.startParameter.taskNames.any { taskName ->
    taskName.contains("release", ignoreCase = true)
}

// Device probes must never share the Play Store package, deep-link handlers, or
// app-private storage. Each opt-in harness has a separate identity so permission
// denial state cannot contaminate either production or the recording lab.
val productionApplicationId = "com.ores.sonus_auris"
val deviceLabAndroidBuild = System.getenv("SONUS_DEVICE_LAB_ANDROID") == "1"
val permissionLabAndroidBuild = System.getenv("SONUS_PERMISSION_LAB_ANDROID") == "1"
if (deviceLabAndroidBuild && permissionLabAndroidBuild) {
    throw GradleException(
        "SONUS_DEVICE_LAB_ANDROID and SONUS_PERMISSION_LAB_ANDROID are mutually exclusive."
    )
}
val resolvedApplicationId = when {
    deviceLabAndroidBuild -> "$productionApplicationId.device_lab"
    permissionLabAndroidBuild -> "$productionApplicationId.permission_lab"
    else -> productionApplicationId
}
val resolvedAppLabel = when {
    deviceLabAndroidBuild -> "Sonus Auris Device Lab"
    permissionLabAndroidBuild -> "Sonus Auris Permission Lab"
    else -> "Sonus Auris"
}
val resolvedUriScheme = when {
    deviceLabAndroidBuild -> "sonusauris-device-lab"
    permissionLabAndroidBuild -> "sonusauris-permission-lab"
    else -> "sonusauris"
}

val releaseSigningMaterial = if (releaseTaskRequested) {
    if (deviceLabAndroidBuild || permissionLabAndroidBuild) {
        throw GradleException(
            "DEN-2843: device and permission lab identities are debug-only and cannot run release tasks",
        )
    }
    if (!keystorePropertiesFile.isFile || !keystorePropertiesFile.canRead()) {
        throw GradleException(
            "DEN-2843: android/key.properties is required for every Android release task",
        )
    }

    val properties = Properties()
    FileInputStream(keystorePropertiesFile).use(properties::load)
    val storePath = requiredReleaseProperty(properties, "storeFile", trim = true)
    val storePassword = requiredReleaseProperty(properties, "storePassword")
    val keyAlias = requiredReleaseProperty(properties, "keyAlias", trim = true)
    val keyPassword = requiredReleaseProperty(properties, "keyPassword")
    if (keyAlias.equals("androiddebugkey", ignoreCase = true)) {
        throw GradleException("DEN-2843: the Android debug key alias is forbidden for releases")
    }

    val keystore = file(storePath).canonicalFile
    val defaultDebugKeystore = File(System.getProperty("user.home"), ".android/debug.keystore")
        .canonicalFile
    if (!keystore.isFile || !keystore.canRead()) {
        throw GradleException("DEN-2843: release keystore must be an existing readable file")
    }
    if (keystore == defaultDebugKeystore || keystore.name.equals("debug.keystore", ignoreCase = true)) {
        throw GradleException("DEN-2843: the Android debug keystore is forbidden for releases")
    }

    val keyStore = loadReleaseKeyStore(keystore, storePassword.toCharArray())
    try {
        keyStore.getKey(keyAlias, keyPassword.toCharArray())
            ?: throw GradleException("DEN-2843: release key alias has no private key")
    } catch (error: GradleException) {
        throw error
    } catch (error: Exception) {
        throw GradleException("DEN-2843: release key password is invalid", error)
    }
    val expectedFingerprint = normalizeSha256Fingerprint(
        requiredReleaseEnvironment("SONUS_ANDROID_UPLOAD_CERT_SHA256"),
    )
    if (certificateSha256(keyStore, keyAlias) != expectedFingerprint) {
        throw GradleException(
            "DEN-2843: release certificate SHA-256 does not match the owner-pinned upload fingerprint",
        )
    }

    ReleaseSigningMaterial(
        keystore = keystore,
        storePassword = storePassword,
        keyAlias = keyAlias,
        keyPassword = keyPassword,
    )
} else {
    null
}

android {
    namespace = "com.ores.sonus_auris"
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
        // Permanent Play Store identity unless one explicit debug-only lab
        // switch selects an isolated package above.
        applicationId = resolvedApplicationId
        manifestPlaceholders["sonusAppLabel"] = resolvedAppLabel
        manifestPlaceholders["sonusUriScheme"] = resolvedUriScheme
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
        releaseSigningMaterial?.let { material ->
            create("release") {
                keyAlias = material.keyAlias
                keyPassword = material.keyPassword
                storeFile = material.keystore
                storePassword = material.storePassword
            }
        }
    }

    buildTypes {
        release {
            releaseSigningMaterial?.let {
                signingConfig = signingConfigs.getByName("release")
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
