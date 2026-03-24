import java.util.Properties
import org.gradle.api.GradleException

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("app/key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

val requiredReleaseSigningProperties = listOf(
    "storePassword",
    "keyPassword",
    "keyAlias",
    "storeFile",
)
val missingReleaseSigningProperties = requiredReleaseSigningProperties.filter {
    keystoreProperties.getProperty(it).isNullOrBlank()
}
val releaseStoreFilePath = keystoreProperties.getProperty("storeFile")
    ?.takeIf { it.isNotBlank() }
val releaseStoreFile = releaseStoreFilePath?.let { file(it) }
val hasCompleteReleaseSigningConfig = keystorePropertiesFile.exists() &&
    missingReleaseSigningProperties.isEmpty() &&
    releaseStoreFile?.exists() == true
val isReleaseBuildRequested = gradle.startParameter.taskNames.any { taskName ->
    taskName.contains("Release", ignoreCase = true)
}

if (isReleaseBuildRequested) {
    when {
        !keystorePropertiesFile.exists() -> throw GradleException(
            "Release builds require Android signing configuration in android/app/key.properties. " +
                "Copy android/app/key.properties.example and provide a real release keystore, " +
                "or use a debug build for local development.",
        )
        missingReleaseSigningProperties.isNotEmpty() -> throw GradleException(
            "Release builds require complete Android signing configuration in android/app/key.properties. " +
                "Missing: ${missingReleaseSigningProperties.joinToString(", ")}.",
        )
        releaseStoreFile?.exists() != true -> throw GradleException(
            "Release builds require a valid Android keystore. " +
                "Configured storeFile '${releaseStoreFilePath ?: "(missing)"}' was not found.",
        )
    }
}

android {
    namespace = "xyz.depollsoft.monkeyssh"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    signingConfigs {
        if (hasCompleteReleaseSigningConfig && releaseStoreFile != null) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = releaseStoreFile
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    defaultConfig {
        applicationId = "xyz.depollsoft.monkeyssh"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "environment"

    productFlavors {
        create("private") {
            dimension = "environment"
            applicationIdSuffix = ".private"
            resValue("string", "app_name", "MonkeySSH β")
        }
        create("production") {
            dimension = "environment"
            resValue("string", "app_name", "MonkeySSH")
        }
    }

    buildTypes {
        release {
            if (hasCompleteReleaseSigningConfig) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("eu.simonbinder:sqlite3-native-library:3.51.1")
}
