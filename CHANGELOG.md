# 更新记录

## 0.1.10-rc.1 / HAR 0.1.9-rc.1（2026-10-23，发布候选）

- Android/OHOS 转账提交受理后释放发送槽，保留有界且不阻塞的精确回执关联；微信未登录返回后可再次拉起。iOS 原有转账提交即释放合同通过回归核对。
- OHOS 同 AppID 配置刷新实际调用方 context，每笔请求固定 context，保留唯一 SDK。
- 不保存业务领取状态；已受理转账不再占用持久 journal，跨进程状态由服务端核实。

## HAR 0.1.8-rc.1（2026-10-18）

- OHOS 修复 early receipt 与 owner 清理重入时序；独立候选标签 `har-0.1.8-rc.1`，Maven `0.1.9`、Git Pod / SPM `native-0.1.9` 保持不变。
- HAR 构建及公开 Release 精确消费由组件专用 Jenkins 入口分别执行；源码、checksum、公开消费、Registry 与设备业务分别记录，准备状态不表示已发布。

## 0.1.7（2026-10-08）

- Swift OAuth 参数按 UTF-16 限额验证；Swift/OHOS 监听回放在撤销或替换后停止，OHOS 实时监听快照避免重入重复投递。配套 native-0.1.6 / HAR 0.1.6；收窄 CI 到源码、轻量 main 与精确 Release 消费。

## 0.1.6（2026-10-08）

- iOS指定联系人图片请求；三端UTF16/UTF8截断合同；OHOS URL按UTF8限制10KiB；保留可信回执归属。
- 更新功能、测试覆盖与平台差异文档；设备业务验收范围保持明确。

## 未发布

- iOS 指定联系人图片分享使用现用 SDK 2.0.7 的正式场景和收件人字段，携带可信发送者 openID；移除未有真实兼容故障证据的全量 Unsupported。无效参数、普通分享、取消和迟回执门禁沿用既有合同。
- 生产分享方法/回执回归、真实官方 SDK 类型检查通过；指定收件人真机发送尚未验收。

## native-0.1.4（2026-10-05）

- GycWechatNative Pod内部版本0.1.4，source使用独立不可变native-0.1.4 Git标签；标签固定本版提交，旧标签不覆盖。
- Swift拒绝成功OAuth回包的nil/空/纯Unicode空白code，与Android/OHOS错误语义一致，合法code原文保留。
- Maven0.1.5/HAR0.1.4及原协议保留；本native标签不产生新Maven坐标。
- [完整12个生产文件审查与直接Swift回执回归](docs/完整源码审查.md)完成；真实WechatOpenSDK-XCFramework2.0.7全源码编译及UIKit App最终链接通过；真实远程 Git Pod/UIKit App 与 Swift Package/device 编译通过，详见[发布验收](docs/native-0.1.4发布验收.md)。
