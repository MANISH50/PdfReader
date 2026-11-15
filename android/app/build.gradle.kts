import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// Release signing.
//
// Values come from (first match wins, per value):
//   1. environment variables (CI):  PDFREADER_KEYSTORE_PATH, PDFREADER_KEYSTORE_PASSWORD,
//                                   PDFREADER_KEY_ALIAS, PDFREADER_KEY_PASSWORD
//   2. android/key.properties (local, gitignored; see key.properties.example):
//                                   storeFile, storePassword, keyAlias, keyPassword
//
// If nothing is configured, local release builds fall back to the DEBUG key with
// a loud warning (fine for testing, never for distribution). Set
// PDFREADER_REQUIRE_RELEASE_SIGNING=true (release CI) to make that a hard error.
// A partial configuration is always a hard error.
// Never commit keystores or passwords.
// ---------------------------------------------------------------------------
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.isFile) file.inputStream().use { load(it) }
}

fun signingValue(envName: String, propName: String): String? =
    System.getenv(envName)?.takeIf { it.isNotBlank() }
        ?: keystoreProperties.getProperty(propName)?.takeIf { it.isNotBlank() }

val releaseStoreFile = signingValue("PDFREADER_KEYSTORE_PATH", "storeFile")
val releaseStorePassword = signingValue("PDFREADER_KEYSTORE_PASSWORD", "storePassword")
val releaseKeyAlias = signingValue("PDFREADER_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = signingValue("PDFREADER_KEY_PASSWORD", "keyPassword")
val releaseSigningValues = listOf(releaseStoreFile, releaseStorePassword, releaseKeyAlias, releaseKeyPassword)
val hasReleaseSigning = releaseSigningValues.all { it != null }
val requireReleaseSigning = System.getenv("PDFREADER_REQUIRE_RELEASE_SIGNING") == "true"

if (!hasReleaseSigning && releaseSigningValues.any { it != null }) {
    throw GradleException(
        "Incomplete release signing config: set all of storeFile/storePassword/keyAlias/keyPassword " +
            "(or the PDFREADER_KEYSTORE_PATH/_PASSWORD/_KEY_ALIAS/_KEY_PASSWORD env vars).",
    )
}
if (!hasReleaseSigning && requireReleaseSigning) {
    throw GradleException("PDFREADER_REQUIRE_RELEASE_SIGNING=true but no release keystore is configured.")
}

android {
    // Kotlin/Java package of MainActivity; independent of the store identity below.
    namespace = "com.pdfreader.pdfreader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.pdfreader.app"
        // 24 = Flutter's minimum and url_launcher_android's minimum; PDFium binaries need no more.
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
                enableV1Signing = false // minSdk 24: v2+ only
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            isDebuggable = false
            isJniDebuggable = false
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                logger.error( // error level so it shows even in Flutter's quiet Gradle output
                    "\n" +
                        "=====================================================================\n" +
                        "  WARNING: no release keystore configured (android/key.properties or\n" +
                        "  PDFREADER_KEYSTORE_* env vars). The RELEASE build will be signed\n" +
                        "  with the DEBUG key. Do NOT distribute this APK/AAB.\n" +
                        "=====================================================================",
                )
                signingConfigs.getByName("debug")
            }
        }
    }

    // Do not embed the Google-signed dependency metadata block in the APK/AAB:
    // it is opaque to users and not needed by a fully offline app.
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
