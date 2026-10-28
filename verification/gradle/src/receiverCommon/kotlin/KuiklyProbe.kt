import io.github.gycrosskit.wechat.WechatKind
import io.github.gycrosskit.wechat.WechatReceipt
import io.github.gycrosskit.wechat.WechatScene
import io.github.gycrosskit.wechat.WechatTransferPageStatus
import io.github.gycrosskit.wechat.kuikly.WechatModule

fun kuiklyModuleProbe() = io.github.gycrosskit.wechat.kuikly.WechatModule()

fun receiptProjectionProbe(receipt: WechatReceipt) = receipt.routingRequestId to receipt.transferPageStatus
fun transferPageResultProbe() = WechatTransferPageStatus.from(0, "success")
fun transferOwnershipProbe(module: WechatModule) = module.supportsTransferReceiptOwnership

// 只编译新增公开入口；消费者验证不实际发起微信业务。
suspend fun base64SubmissionProbe(module: WechatModule) =
    module.awaitSubmission("image-probe", WechatKind.SHARE) {
        shareImageBase64("image-probe", "AQ==", WechatScene.SESSION, maximumBytes = 1024)
    }
