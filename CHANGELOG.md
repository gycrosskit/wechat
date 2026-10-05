# 更新记录

## native-0.1.4（2026-10-05）

- GycWechatNative Pod内部版本0.1.4，source使用独立不可变native-0.1.4 Git标签；标签固定本版提交，旧标签不覆盖。
- Swift拒绝成功OAuth回包的nil/空/纯Unicode空白code，与Android/OHOS错误语义一致，合法code原文保留。
- Maven0.1.5/HAR0.1.4及原协议保留；本native标签不产生新Maven坐标。
- [完整12个生产文件审查与直接Swift回执回归](docs/完整源码审查.md)完成；真实WechatOpenSDK-XCFramework2.0.7全源码编译及UIKit App最终链接通过；真实远程 Git Pod/UIKit App 与 Swift Package/device 编译通过，详见[发布验收](docs/native-0.1.4发布验收.md)。
