plugins {
    alias(libs.plugins.kotlin.multiplatform)
    `maven-publish`
}

kotlin {
    ohosArm64()
    sourceSets {
        commonMain.dependencies {
            api(project(":wechat-core"))
            implementation(libs.kuikly.core)
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2-1.0.0")
        }
    }
}
