import java.security.MessageDigest
import groovy.json.JsonOutput

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 每次 Android 构建自动记录实际源码输入指纹（包括未提交文件）。
// 热重载不会重建 native：诊断端明确标注该限制，不能拿它冒充热重载后源码版本。
val sourceRoot = projectDir.resolve("../..").canonicalFile
fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256")
    .digest(bytes).joinToString("") { "%02x".format(it) }
fun readDiagnosticInputs() = fileTree(sourceRoot) {
    include("lib/**", "tool/*.dart", "assets/**", "shaders/**", "pubspec.yaml", "pubspec.lock")
    include("android/app/src/**", "android/**/*.gradle.kts", "android/gradle.properties")
}.files.filter { it.isFile }.sortedBy { it.relativeTo(sourceRoot).invariantSeparatorsPath }
    .associate { it.relativeTo(sourceRoot).invariantSeparatorsPath to sha256(it.readBytes()) }
val diagnosticInputs = readDiagnosticInputs()
val diagnosticTarget = project.findProperty("target")?.toString() ?: "lib/main.dart"
val diagnosticDefinesHash = sha256((project.findProperty("dart-defines")?.toString() ?: "").toByteArray())
val diagnosticBuildId = sha256((diagnosticInputs.entries.joinToString("\n") { "${it.key}:${it.value}" }
    + "\ntarget=$diagnosticTarget\ndefines=$diagnosticDefinesHash").toByteArray())
val diagnosticManifest = sourceRoot.resolve("build/diagnostics/$diagnosticBuildId.json")
diagnosticManifest.parentFile.mkdirs()
val diagnosticManifestData = mapOf(
    "buildId" to diagnosticBuildId, "target" to diagnosticTarget,
    "definesHash" to diagnosticDefinesHash, "files" to diagnosticInputs,
    "scope" to "android_source_snapshot_no_hot_reload",
    "sourceConsistency" to "not_checked"
)
diagnosticManifest.writeText(JsonOutput.toJson(diagnosticManifestData))
tasks.matching { it.name.startsWith("assemble") }.configureEach {
    doLast {
        val consistency = if (readDiagnosticInputs() == diagnosticInputs)
            "unchanged_through_build" else "changed_during_build"
        diagnosticManifest.writeText(JsonOutput.toJson(
            diagnosticManifestData + ("sourceConsistency" to consistency)))
    }
}

android {
    buildFeatures { buildConfig = true }
    namespace = "com.example.aicove_flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.aicove_flutter"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("String", "DIAGNOSTIC_BUILD_ID", "\"$diagnosticBuildId\"")
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
