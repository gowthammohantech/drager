// sb-jvm: interop test CLI (docs/API/CONFORMANCE.md §5). Never shipped in the app.
plugins {
    alias(libs.plugins.kotlin.jvm)
    application
}

kotlin { jvmToolchain(17) }

application {
    applicationName = "sb-jvm"
    mainClass.set("com.spatialbridge.cli.MainKt")
}

dependencies {
    implementation(project(":core"))
    // tls-echo --cipher-suite (test-only downgrade probe) builds its own BouncyCastle peer.
    implementation(libs.bcprov)
    implementation(libs.bctls)
}
