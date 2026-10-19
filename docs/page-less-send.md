# 免跳页发送(不打开聊天页)

## 结论

40.7.0 里文本消息的**真正发送点不在聊天页组件**,而在:

```
AWEIMSendMessageController
- (id)sendMessage:(id)context
     conversation:(id)conversation
   forwardMessage:(BOOL)forward
     mentionUsers:(id)mentionUsers
        enterFrom:(id)enterFrom;      // @52@0:8@16@24B32@36@44
```

全二进制里只有 `AWEIMSendMessageController` 实现它(`objc_dump.py methods` 查证)。
聊天页组件的 `sendMessage:mentionUsers:customToast:enterFrom:` 只是把「上下文 + 会话」
转交给它。因此**只要手里有目标会话的 conversation 模型,就能不打开聊天页直接投递**。

反过来的证据:文本这条路没有"按 conversationID 直发"的 API ——
`sendMessageWithContext:` 只有组件实现;`sendTextMessageInConversation:...` 那一族
属于 Pigeon/ECOM 企业客服 IM,不是好友聊天;`IESIMMessageSender` 是 TIM SDK 层,
需要现成的 TIM 消息对象。所以"会话对象"是绕不开的入参。

## 实现

1. `Tweak.x` 的 `AWEIMMessageListViewModel setConversation:` 里顺手把会话模型按
   uid/cid 缓存进 `SparksEngine.conversations`。
2. 发送时先走 `-sendTextWithoutPage:target:`:有缓存的会话模型 → 组
   `AWEIMSendMessageContext`(content/userInfo/enterFrom,与页面路径完全一致)→
   直接调底层控制器,页面不动。
3. 返回 NO(没缓存过 / 类缺失 / 抛异常)→ 自动回退 v2.16 的"打开聊天页 + 等组件"路径。
4. 新增 `AWEIMSendMessageController` 钩子,解决免跳页路径拿不到发送回执的问题。

## 注意

- 会话模型是**内存对象**:进程重启后需要再打开一次对应聊天才会重新缓存。
  插件本来要求"首次手动发一条校准",所以实际使用中每天第一轮前打开一两次即可。
- 没在真机上验证过"越久远的会话模型还能不能发"。若投递后回执未到 / 消息没进会话,
  面板日志会显示"未捕获回执",此时把目标重新打开一次即可恢复。
- 媒体(图片/GIF/TTS 语音)本来就走 `AWEIMSendAttachmentController`(只吃 conversationID),
  与本次改动无关,始终免跳页。
