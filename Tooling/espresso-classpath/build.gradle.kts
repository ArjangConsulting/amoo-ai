// Resolves a real Espresso/JUnit/Hamcrest classpath for compile-verifying generated Kotlin
// (see Tests/TestCodeGeneratorTests/CompileVerification.swift). Not part of the app build.
plugins {
    id("java-library")
}

repositories {
    google()
    mavenCentral()
}

val espressoClasspath: Configuration by configurations.creating
val composeAndroidArtifacts: Configuration by configurations.creating
val testCommonsAndroidArtifacts: Configuration by configurations.creating

val testCommonsVersion = "0.1.0"

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.09.00")
    espressoClasspath(composeBom)
    espressoClasspath("androidx.test.espresso:espresso-core:3.7.0")
    espressoClasspath("androidx.test.ext:junit:1.3.0")
    espressoClasspath("androidx.compose.ui:ui-test-junit4")
    // A plain java-library configuration selects Compose's JVM stub variant. Resolve the Android
    // AAR separately so module conflict resolution cannot replace it with that stub variant.
    composeAndroidArtifacts("androidx.compose.ui:ui-test-junit4-android:1.12.0@aar") { isTransitive = false }
    espressoClasspath("androidx.compose.ui:ui-test-manifest")
    espressoClasspath("androidx.compose.ui:ui")
    espressoClasspath("androidx.compose.foundation:foundation")
    espressoClasspath("androidx.activity:activity-compose:1.12.3")
    espressoClasspath("junit:junit:4.13.2")
    espressoClasspath("androidx.test.uiautomator:uiautomator:2.4.0")
    // KotlinTestCommons publishes Android AARs. The JVM-only Gradle variant of the same coordinates
    // would not contain the Espresso, UiAutomator, or Compose-rule helpers generated tests call.
    listOf("core", "device", "compose").forEach { module ->
        testCommonsAndroidArtifacts("io.github.maniramezan.testcommons:$module-android:$testCommonsVersion@aar") {
            isTransitive = false
        }
    }
}

tasks.register("printClasspath") {
    doLast {
        (
            espressoClasspath.resolve() + composeAndroidArtifacts.resolve() + testCommonsAndroidArtifacts.resolve()
        ).forEach {
            println("CLASSPATH_ENTRY:${it.absolutePath}")
        }
    }
}
