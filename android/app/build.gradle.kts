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
        versionCode = 3
        versionName = "1.2"
        buildConfigField("String", "ARCGIS_LICENSE", "\"$arcgisLicense\"")
        // arm64: phones of today, which keeps the file small; -PatlasAbi=x86_64 builds one for an emulator on a PC
        ndk { abiFilters += ((findProperty("atlasAbi") as String?) ?: "arm64-v8a").split(",") } // or several, with commas
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
    implementation("androidx.compose.material:material-icons-extended:1.7.8")
    implementation("androidx.activity:activity-compose:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("com.esri:arcgis-maps-kotlin:200.8.3")
    implementation("com.esri:arcgis-maps-kotlin-toolkit-geoview-compose:200.8.3")
    implementation("org.maplibre.gl:android-sdk:13.7.1")
}
