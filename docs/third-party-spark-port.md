# 从「抖音优化 28.59」提取续火花能力并入本插件

被提取对象:`抖音优化_28.59_34b1_无根.deb`
- Package `com.siwenjiajia.tweak`,作者 siwenjiajia,rootless(`/var/jb`)
- 内含 `siwenjiajia.dylib`(11,887,328 字节,thin arm64),ObjC 段名被混淆,但
  `__objc_classname`(217 个类)/ `__objc_methname`(9,420 个选择器)可读

## 它的续火花实现走的是哪条路

从它的字符串和选择器能还原出链路:

| 证据 | 含义 |
|---|---|
| `启用自动续火花` / `定时自动续火花` / `定时执行续火花逻辑` | 定时任务 |
| `选择续火花对象` / `还没有续火花对象` | 目标管理 |
| `连续失败 3 次自动熔断 10 分钟` | 失败熔断 |
| `p_sendMessageWithType:uid:secUID:cid:msg:extraInfo:completion:` | 自己的私下发送封装(入参是 uid/secUID/cid + 文本) |
| `AWEIMModuleService -checkAndCreateSingleConversationWithPeerUid:completion:` | **按 uid 取/建单聊会话** |
| `asyncGetConversationForIdentifier:completion:` | 按会话标识取会话 |
| `TIMXOConversation -sendMessage:isSaveDB:error:` | 拿到会话后直接投递(TIM 层) |

结论:**它根本不打开聊天页** —— 先用 IM 服务把"会话对象"查出来,再投递。
这正好解释了本插件一直以来的痛点:我们的 `AWEIMSendMessageController` 链路是对的,
缺的只是**在没有聊天页时怎么拿到会话对象**。

## 本插件怎么并进来

用最小改动复用已有链路:

```
sendText
 ① 有缓存会话       → sendTextWithoutPage(原逻辑,直接投)
 ② 没有缓存会话语   → sendTextViaIM:调 AWEIMModuleService 按 uid/cid 反查
                     → 拿到会话写进缓存 → 复用 ①(不重复实现投递)
 ③ 只后台模式兜底   → 语音/图片(媒体通道),绝不跳页
 ④ 非只后台模式     → 打开聊天页(老路)
```

新增代码:
- `-spModuleService`:按 `+sharedInstance / +sharedService / +defaultService / +service`,
  再退到 `IESServiceManager/AWEEServiceManager +serviceWithProtocol:` 依次尝试拿服务实例,并打日志说明取自哪条路;
- `-sendTextViaIM:target:completion:`:单聊走 `checkAndCreateSingleConversationWithPeerUid:completion:`,
  群聊走 `asyncGetConversationForIdentifier:completion:`,回调切回主线程后写缓存并投递。

## 已知边界

- 第三方是用 `TIMXOConversation sendMessage:isSaveDB:error:` 自己拼消息投递;本插件没有照抄这段
  (TIMX 消息/元素的构造函数在 40.7.0 里没有可靠签名),而是复用自家已验证的
  `AWEIMSendMessageController sendMessage:conversation:...` —— 两者都需要"会话对象",而会话对象正是这次补上的部分。
- `AWEIMModuleService` 的实例获取方式随版本可能变化,代码里三条路都会试并打日志;
  日志里出现 `✅ IM 模块服务取自 …` 即表示拿到了,出现 `⚠️ 拿不到 AWEIMModuleService 实例` 则需要补一条获取路径。
- 未在真机验证。若日志出现 `⚠️ IM 服务没返回会话`,说明查会话的入参不对(单聊可能要求 secUid 而非 uid),把日志发我。
