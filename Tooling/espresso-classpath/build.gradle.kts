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

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.08.00")
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
}

tasks.register("printClasspath") {
    doLast {
        (espressoClasspath.resolve() + composeAndroidArtifacts.resolve()).forEach {
            println("CLASSPATH_ENTRY:${it.absolutePath}")
        }
    }
}
