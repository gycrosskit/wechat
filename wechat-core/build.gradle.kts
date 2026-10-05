plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.library)
    `maven-publish`
}

kotlin {
    androidTarget {
        publishLibraryVariants("release")
        compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11) }
    }
    jvm()
    iosX64()
    iosArm64()
    iosSimulatorArm64 { binaries.framework { baseName = "WechatCore" } }
    ohosArm64()
    sourceSets {
        androidMain.dependencies {
            implementation("com.tencent.mm.opensdk:wechat-sdk-android:6.8.34")

        }
        androidUnitTest.dependencies {
            implementation("org.robolectric:robolectric:4.16.1")
        }
        commonTest.dependencies { implementation(kotlin("test")) }
        // JVM 测试用薄 Kuikly transport stub 执行实际 Module，避免复制取消协议。
        jvmTest { kotlin.srcDir(rootProject.file("wechat-kuikly/src/commonMain/kotlin")) }
    }
}

android {
    namespace = "io.github.gycrosskit.wechat"
    compileSdk = 36
    defaultConfig { minSdk = 24 }
    testOptions.unitTests.isIncludeAndroidResources = true
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
}
