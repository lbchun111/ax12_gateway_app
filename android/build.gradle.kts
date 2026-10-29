import com.android.build.api.dsl.LibraryExtension

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // flutter_reactive_ble 5.5 keeps Android 9 support, but its Android
    // implementation declares compileSdk 33. Current AndroidX metadata needs
    // compileSdk 34+, so compile that library with the installed SDK 35.
    // This does not change this application's minSdk (API 28 / Android 9).
    if (name == "reactive_ble_mobile") {
        afterEvaluate {
            extensions.configure<LibraryExtension> {
                compileSdk = 35
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
