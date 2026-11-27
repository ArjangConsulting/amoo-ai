import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("com.google.protobuf")
}

android {
    namespace = "com.amoo.companion"
    compileSdk = 34
    testBuildType = if (providers.gradleProperty("amooReleaseCompanion").isPresent) "release" else "debug"

    defaultConfig {
        applicationId = "com.amoo.companion"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            testProguardFile("src/androidTest/companion-test.pro")
            optimization {
                enable = true
            }
        }
    }

    packaging {
        resources {
            excludes += setOf(
                "META-INF/INDEX.LIST",
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/NOTICE",
                "META-INF/NOTICE.txt",
                "META-INF/io.netty.versions.properties",
            )
        }
    }
}

// AGP 9 / Kotlin 2.4 replaced the android { kotlinOptions { } } block with the compilerOptions DSL.
kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

protobuf {
    protoc {
        artifact = "com.google.protobuf:protoc:4.36.2"
    }
    plugins {
        create("grpc") {
            artifact = "io.grpc:protoc-gen-grpc-java:1.86.0"
        }
        create("grpckt") {
            artifact = "io.grpc:protoc-gen-grpc-kotlin:1.5.0:jdk8@jar"
        }
    }
    generateProtoTasks {
        all().forEach { task ->
            task.builtins {
                create("java")
                create("kotlin")
            }
            task.plugins {
                create("grpc")
                create("grpckt")
            }
        }
    }
}

dependencies {
    // AndroidX Test + UIAutomator
    androidTestImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    androidTestImplementation("org.checkerframework:checker-qual:4.4.0")
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test:runner:1.5.2")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.4.1")
    androidTestCompileOnly("com.google.auto.value:auto-value-annotations:1.11.1")
    androidTestImplementation("com.google.android.apps.common.testing.accessibility.framework:accessibility-test-framework:4.1.1") {
        exclude(group = "com.google.protobuf", module = "protobuf-javalite")
    }

    // gRPC for instrumentation tests
    androidTestImplementation("io.grpc:grpc-netty:1.86.0")
    androidTestImplementation("io.grpc:grpc-protobuf:1.86.0")
    androidTestImplementation("io.grpc:grpc-stub:1.86.0")
    androidTestImplementation("io.grpc:grpc-kotlin-stub:1.5.0")
    androidTestImplementation("com.google.protobuf:protobuf-kotlin:4.36.2")
    androidTestImplementation("javax.annotation:javax.annotation-api:1.3.2")
}
