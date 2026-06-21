
import java.util.Properties

plugins {
  id("com.android.application")
  id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")

if (localPropertiesFile.exists()) {
  localPropertiesFile.reader(Charsets.UTF_8).use { reader -> localProperties.load(reader) }
}

val flutterVersionCode = localProperties.getProperty("flutter.versionCode") ?: "1"
val flutterVersionName = localProperties.getProperty("flutter.versionName") ?: "1.0"

android {
  compileSdk = flutter.compileSdkVersion

  namespace = "com.invisiblewrench.fluttermidicommand_example"

  compileOptions {
      sourceCompatibility = JavaVersion.VERSION_11
      targetCompatibility = JavaVersion.VERSION_11
  }

  sourceSets {
    getByName("main").java.srcDirs("src/main/kotlin")
  }

  defaultConfig {
    applicationId = "com.invisiblewrench.fluttermidicommand_example"
    minSdkVersion(24)
    targetSdk = flutter.targetSdkVersion
    versionCode = flutter.versionCode
    versionName = flutter.versionName
  }

  buildTypes { getByName("release") { signingConfig = signingConfigs.getByName("debug") } }



}

flutter { source = "../../" }

kotlin {
  compilerOptions {
    jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11
  }
}
