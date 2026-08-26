plugins {
    id("com.android.application") version "9.3.2" apply false
    id("com.google.protobuf") version "0.10.0" apply false
    // Compose compiler for :composeSampleApp. Must track the Kotlin version AGP's built-in Kotlin
    // uses, since the Compose compiler plugin is versioned in lockstep with Kotlin.
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.0" apply false
}
