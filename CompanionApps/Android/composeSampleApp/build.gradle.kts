import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.amoo.samples.compose"
    // Compose 1.12 (BOM 2026.08.00) compiles against API 37.
    compileSdk = 37

    defaultConfig {
        // Distinct from com.amoo.companion so both install side by side: the companion drives
        // this app from its own process, which is the whole point of the fixture.
        applicationId = "com.amoo.samples.compose"
        minSdk = 26
        targetSdk = 37
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.08.00")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.12.3")

    // This source set is the run target for BOTH emitters' output, so it carries Espresso (for
    // EspressoEmitter) and compose-ui-test (for ComposeEspressoEmitter). Neither emitter had
    // anywhere to actually execute before this module existed — the companion's androidTest is a
    // UIAutomator driver, not a test host.
    androidTestImplementation(composeBom)
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:core:1.7.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
