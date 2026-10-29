package io.github.gycrosskit.wechat

// JVM 只用于核心/传输验证，没有原生微信 SDK。
actual val supportsMerchantTransferReceiptOwnership: Boolean = false
