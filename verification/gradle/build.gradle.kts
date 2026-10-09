plugins {
    kotlin("multiplatform") version "2.2.21-1.0.0"
    id("com.android.library") version "8.10.1"
}
val componentVersion = providers.gradleProperty("wechatVersion").orElse("0.1.8").get()
val verifyNativeModule = providers.gradleProperty("verifyNativeModule").orElse("false").get().toBoolean()
val kuiklyRenderFrameworkDir = providers.gradleProperty("kuiklyRenderFrameworkDir").orNull
kotlin {
    androidTarget()
    iosArm64()
    iosX64 { binaries.framework { baseName = "WechatConsumer"; if (verifyNativeModule) kuiklyRenderFrameworkDir?.let { linkerOpts("-F$it", "-framework", "OpenKuiklyIOSRender") } } }
    iosSimulatorArm64 { binaries.framework { baseName = "WechatConsumer"; if (verifyNativeModule) kuiklyRenderFrameworkDir?.let { linkerOpts("-F$it", "-framework", "OpenKuiklyIOSRender") } } }
    ohosArm64()
    sourceSets {
        commonMain.dependencies { implementation("com.github.gycrosskit.wechat:wechat-core:$componentVersion") }
        if (verifyNativeModule) {
            commonMain { kotlin.srcDir("src/receiverCommon/kotlin") }
            commonMain.dependencies { implementation("com.github.gycrosskit.wechat:wechat-kuikly:$componentVersion") }
            androidMain { kotlin.srcDir("src/receiverAndroid/kotlin") }
        } else {
            ohosArm64Main.dependencies { implementation("com.github.gycrosskit.wechat:wechat-kuikly:$componentVersion") }
        }
    }
}
android { namespace = "io.github.gycrosskit.wechat.consumer"; compileSdk = 36; defaultConfig { minSdk = 24 } }
