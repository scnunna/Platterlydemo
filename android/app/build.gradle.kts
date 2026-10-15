import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Release signing: CI passes PL_* env vars from GitHub secrets; locally ~/.platterly/keystore.properties.
// The keystore never lives in the repo. Obtainium only updates an app signed with the same key.
val signingProps = Properties().apply {
    val f = File(System.getProperty("user.home"), ".platterly/keystore.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
fun signing(env: String, prop: String): String? = System.getenv(env) ?: signingProps.getProperty(prop)
val buildNumber = (System.getenv("PL_BUILD_NUMBER") ?: "0").toInt()

// The web app (../web) ships inside the APK as the offline fallback.
val copyWeb by tasks.registering(Sync::class) {
    from(rootProject.file("../web"))
    into(layout.buildDirectory.dir("generated/webassets/web"))
}

android {
    namespace = "com.nunna.platterly"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.nunna.platterly"
        minSdk = 26
        targetSdk = 36
        versionCode = 1000 + buildNumber
        versionName = "0.1.$buildNumber"
    }
    signingConfigs {
        create("release") {
            val store = signing("PL_KEYSTORE_FILE", "storeFile")
            if (store != null) {
                storeFile = file(store)
                storePassword = signing("PL_KEYSTORE_PASSWORD", "storePassword")
                keyAlias = signing("PL_KEY_ALIAS", "keyAlias")
                keyPassword = signing("PL_KEY_PASSWORD", "keyPassword")
            }
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("release").takeIf { it.storeFile != null }
        }
    }
    sourceSets["main"].assets.srcDir(layout.buildDirectory.dir("generated/webassets"))
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    lint { checkReleaseBuilds = false }
    testOptions { unitTests { isIncludeAndroidResources = true } }
}
kotlin { jvmToolchain(17) }

tasks.named("preBuild") { dependsOn(copyWeb) }

dependencies {
    implementation("androidx.webkit:webkit:1.14.0")
    testImplementation("junit:junit:4.13.2")
}
