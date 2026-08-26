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
    }
}

rootProject.name = "AmooCompanion"

// The gRPC companion driver. Built by `make companion-android-build`.
include(":app")

// Fixture app under test, used to verify generated test code actually runs against a real
// Jetpack Compose UI. Opt-in: built by `make sample-app-compose-build`, not by the companion
// target, so adding sample apps never slows the companion build down.
include(":composeSampleApp")
