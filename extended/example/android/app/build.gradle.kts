import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// A define file reaches Gradle only as this comma list of base64 entries.
val dartDefines: Map<String, String> =
    (findProperty("dart-defines") as String?).orEmpty()
        .split(',')
        .filter { it.isNotEmpty() }
        .map { String(Base64.getDecoder().decode(it)) }
        .associate { it.substringBefore('=') to it.substringAfter('=') }

android {
    namespace = "id.tracive.sdk.extended.tracive_sdk_extended_example"
    // The Tracive AARs declare this as their minimum.
    compileSdk { version = release(37) }

    compileOptions {
        // Dates in the Tracive SDKs read java.time, which API 24 and 25 do not have without this.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "id.tracive.sdk.extended.tracive_sdk_extended_example"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["traciveRedirectScheme"] =
            dartDefines["TRACIVE_REDIRECT_SCHEME"] ?: "tracive-extended-flutter-sandbox"
    }

    buildTypes {
        release {
            // TODO(partner): a release keystore of your own.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
