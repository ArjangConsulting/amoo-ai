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

dependencies {
    espressoClasspath("androidx.test.espresso:espresso-core:3.7.0")
    espressoClasspath("androidx.test.ext:junit:1.3.0")
    espressoClasspath("junit:junit:4.13.2")
}

tasks.register("printClasspath") {
    doLast {
        espressoClasspath.resolve().forEach { println("CLASSPATH_ENTRY:${it.absolutePath}") }
    }
}
