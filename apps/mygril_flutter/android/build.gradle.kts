import java.io.File

fun namespaceFromManifest(projectDir: File): String? {
    val manifest = File(projectDir, "src/main/AndroidManifest.xml")
    if (!manifest.exists()) return null
    val packageRegex = Regex("""\bpackage\s*=\s*"([^"]+)"""")
    val match = packageRegex.find(manifest.readText())
    return match?.groupValues?.getOrNull(1)
}

fun parseCompileSdk(value: Any?): Int? {
    return when (value) {
        is Int -> value
        is String -> Regex("""\d+""").find(value)?.value?.toIntOrNull()
        else -> null
    }
}

fun getCompileSdk(androidExtension: Any): Int? {
    val getterNames = listOf("getCompileSdk", "getCompileSdkVersion")
    for (name in getterNames) {
        val getter =
            androidExtension.javaClass.methods.firstOrNull {
                it.name == name && it.parameterCount == 0
            } ?: continue
        val value = runCatching { getter.invoke(androidExtension) }.getOrNull()
        val parsed = parseCompileSdk(value)
        if (parsed != null) return parsed
    }
    return null
}

fun setCompileSdk(androidExtension: Any, compileSdk: Int): Boolean {
    val setterNames = listOf("setCompileSdk", "setCompileSdkVersion", "compileSdkVersion")
    for (name in setterNames) {
        val candidates =
            androidExtension.javaClass.methods.filter {
                it.name == name && it.parameterCount == 1
            }
        for (method in candidates) {
            val parameterType = method.parameterTypes.firstOrNull() ?: continue
            val result =
                runCatching {
                    when (parameterType) {
                        Int::class.javaPrimitiveType,
                        Int::class.javaObjectType -> method.invoke(androidExtension, compileSdk)
                        String::class.java -> method.invoke(androidExtension, compileSdk.toString())
                        else -> method.invoke(androidExtension, compileSdk)
                    }
                }
            if (result.isSuccess) return true
        }
    }
    return false
}

allprojects {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
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

subprojects {
    pluginManager.withPlugin("com.android.library") {
        val androidExtension = extensions.findByName("android") ?: return@withPlugin
        val appAndroidExtension = rootProject.project(":app").extensions.findByName("android")
        val appCompileSdk = appAndroidExtension?.let { getCompileSdk(it) }
        val targetCompileSdk = appCompileSdk ?: 35

        val currentCompileSdk = getCompileSdk(androidExtension)
        if (currentCompileSdk == null || currentCompileSdk < targetCompileSdk) {
            setCompileSdk(androidExtension, targetCompileSdk)
        }

        val getNamespace =
            androidExtension.javaClass.methods.firstOrNull {
                it.name == "getNamespace" && it.parameterCount == 0
            } ?: return@withPlugin
        val setNamespace =
            androidExtension.javaClass.methods.firstOrNull {
                it.name == "setNamespace" && it.parameterCount == 1
            } ?: return@withPlugin

        val currentNamespace = getNamespace.invoke(androidExtension) as? String
        if (!currentNamespace.isNullOrBlank()) return@withPlugin

        val derived =
            namespaceFromManifest(project.projectDir)
                ?: "com.generated.${project.name.replace('-', '_')}"
        setNamespace.invoke(androidExtension, derived)
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
