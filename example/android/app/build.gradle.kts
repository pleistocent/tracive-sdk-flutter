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

    // Checked in rather than left to the debug keystore AGP generates per machine in
    // `~/.android` (`%USERPROFILE%\.android` on Windows). That one differs for every
    // developer, and on CI it differs for every *run* — the runner is ephemeral, so
    // `flutter build apk --debug` mints a fresh certificate each time and no two APKs
    // out of CI can be installed over one another. `INSTALL_FAILED_UPDATE_INCOMPATIBLE`
    // reads as a broken build rather than as a different signer.
    //
    // Committed, the example has one certificate on every machine and every run, and one
    // SHA-256 to register with Tracive if the redirect ever moves from a private-use
    // scheme to an App Link:
    // 32:DC:A1:F1:EA:69:FC:EA:DC:75:78:A6:FA:4C:ED:08:B2:F6:1F:8B:8F:F7:55:22:2E:D2:77:72:22:6A:41:71
    //
    // Committable only because it is the well-known Android debug identity — alias
    // `androiddebugkey`, password `android` — which Play rejects on upload. The
    // `**/*.keystore` rule in `example/android/.gitignore` still blocks every other one;
    // this file is its single negation.
    signingConfigs {
        getByName("debug") {
            // Resolved against this module rather than the working directory, so the path
            // is the same whether Gradle was invoked by `flutter build` from `example/` or
            // directly from `example/android/`, on either OS.
            storeFile = layout.projectDirectory.file("debug.keystore").asFile
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        release {
            // Debug keys, so `flutter run --release` works out of the box. Fine for a
            // sample; not fine for anything you ship.
            //
            // TODO(partner): a release keystore of your own, kept outside version control
            // and read from `key.properties` — see https://flutter.dev/to/reference-keystore
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
