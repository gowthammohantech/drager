// Pure-JVM protocol core shared by the Android app and the sb-jvm CLI.
// Must only use JDK APIs available on Android (minSdk 28) and must not register a JCA provider.
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

kotlin { jvmToolchain(17) }

dependencies {
    api(libs.coroutines.core)
    implementation(libs.serialization.json)
    implementation(libs.bcprov)
    implementation(libs.bctls)

    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testImplementation(libs.coroutines.test)
    testRuntimeOnly(libs.junit.launcher)
}

tasks.test {
    useJUnitPlatform()
    // Tests read Conformance/vectors and the Swift gesture fixtures in place.
    systemProperty("sb.repoRoot", rootDir.resolve("../..").canonicalPath)
}
