plugins {
    alias(libs.plugins.kotlin.multiplatform) apply false
    alias(libs.plugins.android.library) apply false
}
allprojects {
    group = providers.environmentVariable("GROUP").orElse("com.github.gycrosskit.wechat").get()
    version = providers.environmentVariable("VERSION").orElse("0.1.3").get()
}

subprojects {
    plugins.withId("maven-publish") {
        extensions.configure<org.gradle.api.publish.PublishingExtension> {
            repositories.maven {
                name = "staging"
                url = rootProject.layout.buildDirectory.dir("maven").get().asFile.toURI()
            }
        }
    }
}
