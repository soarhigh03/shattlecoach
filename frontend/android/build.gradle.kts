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

    // Third-party plugins like tflite_flutter still pin Java 1.8 in their own
    // build.gradle, while Kotlin 2.3 defaults to the JDK's bytecode level (21
    // on most dev machines). AGP 9 rejects the mismatch. finalizeDsl runs after
    // the plugin's android {} block but before AGP locks the DSL, so it's the
    // one safe place to bump both Java and Kotlin targets in lock-step.
    plugins.withId("com.android.library") {
        extensions.configure<
            com.android.build.api.variant.LibraryAndroidComponentsExtension
        >("androidComponents") {
            finalizeDsl { dsl ->
                dsl.compileOptions.sourceCompatibility = JavaVersion.VERSION_17
                dsl.compileOptions.targetCompatibility = JavaVersion.VERSION_17
                // tflite_flutter still pins compileSdk 31; some transitive
                // AndroidX deps from the forced tensorflow-lite 2.16.1 need 34+.
                if ((dsl.compileSdk ?: 0) < 36) {
                    dsl.compileSdk = 36
                }
            }
        }
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>()
            .configureEach {
                compilerOptions {
                    jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
                }
            }
    }

    // tflite_flutter 0.11.0 pins tensorflow-lite 2.11.0, where all three
    // artifacts share the namespace `org.tensorflow.lite`. AGP 8+ rejects
    // that. 2.13+ split them into per-artifact namespaces, so we force-upgrade.
    configurations.configureEach {
        resolutionStrategy.eachDependency {
            if (requested.group == "org.tensorflow" &&
                requested.name.startsWith("tensorflow-lite")
            ) {
                useVersion("2.16.1")
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
