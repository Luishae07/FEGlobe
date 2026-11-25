plugins {
    id("com.android.application") version "9.5.3" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.3.21" apply false
}
buildscript {
    dependencies {
        // the Kotlin compiler that the Android plugin uses: the same version as the Compose plugin
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.3.21")
    }
}
