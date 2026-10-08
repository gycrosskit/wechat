plugins {
    kotlin("multiplatform") version "2.2.21-1.0.0"
    id("com.android.library") version "8.10.1"
}
val componentVersion = providers.gradleProperty("wechatVersion").orElse("0.1.7").get()
kotlin {
    androidTarget()
    iosArm64()
    iosX64 { binaries.framework { baseName = "WechatConsumer" } }
    iosSimulatorArm64 { binaries.framework { baseName = "WechatConsumer" } }
    ohosArm64()
    sourceSets {
        commonMain.dependencies { implementation("com.github.gycrosskit.wechat:wechat-core:$componentVersion") }
        ohosArm64Main.dependencies { implementation("com.github.gycrosskit.wechat:wechat-kuikly:$componentVersion") }
    }
}
android { namespace = "io.github.gycrosskit.wechat.consumer"; compileSdk = 36; defaultConfig { minSdk = 24 } }
