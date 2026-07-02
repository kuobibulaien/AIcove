allprojects {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://jitpack.io") }
        maven { url = uri("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/") }
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
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 统一所有子项目的 JVM target 为 17，防止老插件 Java/Kotlin target 不一致
subprojects {
    // Kotlin 编译统一到 17
    pluginManager.withPlugin("org.jetbrains.kotlin.android") {
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    }
}

// 为缺少 namespace 的老插件自动补全（AGP 8+ 强制要求 namespace）
subprojects {
    pluginManager.withPlugin("com.android.library") {
        val android = extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)
            ?: return@withPlugin

        if (android.namespace.isNullOrBlank()) {
            // 从 AndroidManifest.xml 的 package 属性读取
            val manifest = file("${project.projectDir}/src/main/AndroidManifest.xml")
            if (manifest.exists()) {
                val pkg = Regex("""\bpackage\s*=\s*"([^"]+)"""")
                    .find(manifest.readText())?.groupValues?.getOrNull(1)
                if (!pkg.isNullOrBlank()) {
                    android.namespace = pkg
                }
            }
            // 兜底：用项目名生成
            if (android.namespace.isNullOrBlank()) {
                android.namespace = "com.generated.${project.name.replace('-', '_')}"
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
