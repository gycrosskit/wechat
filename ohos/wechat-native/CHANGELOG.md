# 0.1.3

- 提供同步 Preferences pending store，保留旧 namespace/pending 字段；业务恢复判断仍由宿主注入。

# 0.1.1

- 图片输入兼容 25 MiB；网页文本按宿主字符策略与 SDK UTF-8 字节上限截断。
- shareImage 增加可选可信 recipientId/senderOpenId；本端 SDK 缺少指定联系人 API，明确 unsupported，不降级普通好友。

# 0.1.0

微信授权、分享和确认页能力，回调只表示 SDK 层回执。

- 增加可信请求存储恢复、初始化前 Want 暂存及迟挂监听的一次回执交付；严格匹配 transaction/type/state，取消及销毁不恢复。
