plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// secrets come from the environment of the build, they are not in the repository
val arcgisLicense: String = System.getenv("ARCGIS_LICENSE") ?: ""
val keystore: String? = System.getenv("ATLAS_KEYSTORE")

android {
    namespace = "org.flowsearch.atlas"
    compileSdk = 36
    defaultConfig {
        applicationId = "org.flowsearch.atlas"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
        buildConfigField("String", "ARCGIS_LICENSE", "\"$arcgisLicense\"")
        ndk { abiFilters += "arm64-v8a" } // phones of today; keeps the file small
    }
    signingConfigs {
        if (keystore != null) {
            create("release") {
                storeFile = file(keystore)
                storePassword = System.getenv("ATLAS_KEYSTORE_PASSWORD")
                keyAlias = "atlas"
                keyPassword = System.getenv("ATLAS_KEYSTORE_PASSWORD")
            }
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release")
        }
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    packaging {
        resources.excludes += listOf("META-INF/DEPENDENCIES", "META-INF/INDEX.LIST")
        jniLibs.useLegacyPackaging = true // native libraries packed small: a much smaller download
    }
    lint { checkReleaseBuilds = false }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.12.00")
    implementation(composeBom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.activity:activity-compose:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("com.esri:arcgis-maps-kotlin:200.8.3")
    implementation("com.esri:arcgis-maps-kotlin-toolkit-geoview-compose:200.8.3")
    implementation("org.maplibre.gl:android-sdk:13.7.1")
}
