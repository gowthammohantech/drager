plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

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
