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

// ---------------------------------------------------------------------------
// Force every Android library subproject to build against compileSdk = 36.
// Some plugins (file_picker 8.x, connectivity_plus older builds) still ship
// with compileSdk = 34 while their transitive dependency
// flutter_plugin_android_lifecycle now requires 36.  Without this override
// the AAR metadata check aborts the whole build.
//
// The `afterEvaluate` hook MUST be registered BEFORE the second
// `subprojects { evaluationDependsOn(":app") }` block below — otherwise all
// subprojects are already evaluated by the time we reach it and Gradle
// throws "Project.afterEvaluate(Action) when the project is already
// evaluated".
// ---------------------------------------------------------------------------
subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    afterEvaluate {
        extensions
            .findByType(com.android.build.gradle.LibraryExtension::class.java)
            ?.apply {
                if ((compileSdk ?: 0) < 36) {
                    compileSdk = 36
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
