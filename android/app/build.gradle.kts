import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use(keystoreProperties::load)
}

// ABIs the app supports, keyed by the name Flutter uses on the command line.
// x86/x86_64 are deliberately absent: no shipped build targets an emulator, and
// the libv2ray aar carries another 65 MB of native code for them.
val supportedAbis = mapOf(
    "android-arm" to "armeabi-v7a",
    "android-arm64" to "arm64-v8a",
)

// `flutter build apk --target-platform android-arm64` and `--split-per-abi`
// both arrive here as a -Ptarget-platform property. With no property (a plain
// `flutter build apk`) the build stays universal across both ARM ABIs.
val requestedAbis: List<String> =
    (project.findProperty("target-platform") as String?)
        ?.split(",")
        ?.mapNotNull { supportedAbis[it.trim()] }
        ?.takeIf { it.isNotEmpty() }
        ?: supportedAbis.values.toList()

// defaultConfig.ndk.abiFilters does NOT filter native libraries that arrive
// inside a dependency, which is exactly where the 30 MB libv2ray cores come
// from -- an arm64-only build still packaged the arm32 one. Excluding the
// unwanted ABIs at packaging time is the mechanism that actually works; it is
// how the aar's x86 libraries were already being dropped.
val excludedAbis = supportedAbis.values.toSet() + setOf("x86", "x86_64") -
    requestedAbis.toSet()

android {
    namespace = "com.chrnet.vpn"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    signingConfigs {
        create("release") {
            val storeFilePath = keystoreProperties.getProperty("storeFile")
            if (!storeFilePath.isNullOrBlank()) {
                storeFile = file(storeFilePath)
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    defaultConfig {
        applicationId = "com.chrnet.vpn"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

    }

    packaging {
        jniLibs {
            excludes += excludedAbis.map { "**/$it/*.so" }.toSet()
        }
    }

    buildTypes {
        release {
            val releaseSigning = signingConfigs.getByName("release")
            if (releaseSigning.storeFile != null) {
                signingConfig = releaseSigning
            }

            // Everything the app actually reaches at runtime is kept by
            // proguard-rules.pro; the rest of the dex and the unused resources
            // pulled in by ML Kit and the support libraries can go.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // RU direct-routing requires bundled geo datasets on Android.
    implementation(files("libs/libv2ray.with-geo.aar"))
}
