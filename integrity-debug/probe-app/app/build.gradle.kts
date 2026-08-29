plugins {
    id("com.android.application") version "8.5.0"
    id("org.jetbrains.kotlin.android") version "1.9.24"
}

android {
    namespace = "dev.redroid.integrityprobe"
    compileSdk = 34
    defaultConfig {
        applicationId = "dev.redroid.integrityprobe"
        minSdk = 24
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

repositories { google(); mavenCentral() }

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    // Play Integrity API (Classic + Standard)
    implementation("com.google.android.play:integrity:1.4.0")
}
