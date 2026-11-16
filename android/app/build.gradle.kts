plugins { id("com.android.application") }

android {
    namespace = "id.naufal.approvegate"
    compileSdk = 36
    defaultConfig {
        applicationId = "id.naufal.approvegate"
        minSdk = 30
        targetSdk = 36
        versionCode = 6
        versionName = "0.2.2"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // Release key: path in AG_KEYSTORE (set in local.mk), password from the macOS Keychain
    // (service approve-gate-keystore), both passed in by `make apk` / `make release`.
    signingConfigs {
        create("release") {
            storeFile = file(System.getenv("AG_KEYSTORE") ?: "/nonexistent")
            storePassword = System.getenv("AG_KEYSTORE_PASSWORD")
            keyAlias = "approvegate"
            keyPassword = System.getenv("AG_KEYSTORE_PASSWORD")
        }
    }
    buildTypes { getByName("release") { isMinifyEnabled = false; signingConfig = signingConfigs.getByName("release") } }
}

// Exact versions live in gradle.lockfile, so the dependency scan checks what actually ships.
// After changing a dependency: ./gradlew :app:dependencies --write-locks
dependencyLocking { lockAllConfigurations() }

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
}
