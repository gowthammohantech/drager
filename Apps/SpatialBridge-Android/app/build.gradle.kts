plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// `-PsbTestBuildType=release` runs the instrumented tests (and `app/e2e/emulator-e2e.sh --release`)
// against the minified release app, to check that R8 left the BouncyCastle TLS client working.
val testAgainstRelease = (findProperty("sbTestBuildType") as String?) == "release"

android {
    namespace = "com.spatialbridge.android"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.gowthammohan.spatialbridge.android"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // The emulator E2E needs `sb-swift serve` on the host; app/e2e/emulator-e2e.sh runs it.
        testInstrumentationRunnerArguments["notAnnotation"] = "com.spatialbridge.android.HostReceiverTest"
    }

    buildTypes {
        release {
            // R8 shrinking and obfuscation. BouncyCastle is used through its lightweight API only; the
            // reflective parts (JCA/JSSE providers) are unreachable and get stripped (proguard-rules.pro).
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Tests call app and core classes the app itself doesn't use; keep those (only those) for
            // test runs. BouncyCastle and the libraries stay shrunk and obfuscated.
            if (testAgainstRelease) {
                proguardFiles("proguard-test-release.pro")
                testProguardFiles("proguard-test-release.pro")
            }
            // Local verification only (`-PsbDebugSignRelease`): real releases are signed outside this build.
            if (project.hasProperty("sbDebugSignRelease")) signingConfig = signingConfigs.getByName("debug")
        }
    }

    testBuildType = if (testAgainstRelease) "release" else "debug"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    testOptions {
        // Plain JVM tests for pure logic; android.* stubs return defaults instead of throwing.
        unitTests.isReturnDefaultValues = true
    }

    lint {
        abortOnError = true
        warningsAsErrors = false
        checkDependencies = false
        // Version-catalog bumps are Lane K's call, not something the app lint should fail on. App-only
        // dependencies are declared inline on purpose (the catalog is owned by the core lane), and
        // targetSdk 36 is the agreed target.
        disable += setOf("GradleDependency", "NewerVersionAvailable", "AndroidGradlePluginVersion", "UseTomlInstead", "OldTargetApi")
    }

    packaging {
        // BouncyCastle jars each ship the same license and OSGi metadata.
        resources.excludes += setOf("META-INF/LICENSE.md", "META-INF/versions/9/OSGI-INF/MANIFEST.MF")
    }
}

dependencies {
    implementation(project(":core"))
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.activity.compose)
    // Extra dependencies declared here (not in the catalog, which Lane K owns). Versions checked on
    // Google Maven / Maven Central; Compose artifacts are pinned by the BOM.
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    if (testAgainstRelease) add("releaseImplementation", "androidx.compose.ui:ui-test-manifest")

    testImplementation("junit:junit:4.13.2")
    testImplementation(libs.coroutines.test)

    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test:rules:1.7.0")
    // ui-test pulls Espresso 3.5, which calls InputManager.getInstance (removed in API 37 images).
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
}
