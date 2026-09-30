import com.tencent.mm.opensdk.constants.Build;
import com.tencent.mm.opensdk.modelmsg.*;
import com.tencent.mm.opensdk.utils.ILog;
import com.tencent.mm.opensdk.utils.Log;
import java.lang.reflect.Proxy;

// 使用真正 SDK 的 checkArgs；只替换日志，不发起微信请求。
class AndroidSdkCheck {
    public static void main(String[] args) {
        Log.setLogImpl((ILog) Proxy.newProxyInstance(ILog.class.getClassLoader(), new Class<?>[]{ILog.class}, (proxy, method, values) -> null));
        WXImageObject image = new WXImageObject(new byte[25 * 1024 * 1024]);
        assert image.checkArgs();
        image.imageData = new byte[25 * 1024 * 1024 + 1];
        assert !image.checkArgs();
        image.imageData = new byte[]{1};
        SendMessageToWX.Req request = new SendMessageToWX.Req();
        request.message = new WXMediaMessage(image);
        request.message.thumbData = new byte[]{1};
        request.scene = SendMessageToWX.Req.WXSceneSession;
        assert request.checkArgs();
        request.scene = SendMessageToWX.Req.WXSceneTimeline;
        assert request.checkArgs();
        request.scene = SendMessageToWX.Req.WXSceneSpecifiedContact;
        request.userOpenId = "trusted-target";
        assert !request.checkArgs(); // 目标 openId 不能替代发送者 openId。
        request.openId = "trusted-sender";
        assert request.checkArgs();
        request.userOpenId = null;
        assert !request.checkArgs();
        assert Build.SEND_TO_SPECIFIED_CONTACT_SDK_INT == 620824064;
        assert Build.SEND_25M_IMAGE_SDK_INT == 620889088;
        System.out.println("Real Android SDK: SESSION/TIMELINE, specified target + sender and 25 MiB checkArgs passed");
    }
}
