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
}
