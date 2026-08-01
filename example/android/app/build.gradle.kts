plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "id.tracive.tracive_sdk_example"
    compileSdk = flutter.compileSdkVersion

    // `ndkVersion` is deliberately NOT set. Flutter's template sets it to
    // `flutter.ndkVersion`, and because it is set explicitly the Android Gradle
    // Plugin resolves that exact NDK at *configuration* time — before it has
    // asked whether anything needs one. Nothing here does: none of this app's
    // plugins (sqflite_sqlcipher, flutter_secure_storage, url_launcher,
    // path_provider) declares an `externalNativeBuild`, a CMakeLists or an
    // `ndkVersion` of its own; they all ship prebuilt. Leaving the line in made
    // the build fail outright on any machine whose NDK was absent or partly
    // installed, with a message about a missing `source.properties` that says
    // nothing about the real cause, and would have had a clean CI runner
    // download roughly a gigabyte for nothing.

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "id.tracive.tracive_sdk_example"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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
