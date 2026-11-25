pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        maven("https://esri.jfrog.io/artifactory/arcgis") // the ArcGIS Maps SDK
    }
}
rootProject.name = "Atlas"
include(":app")
