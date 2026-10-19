# 抖音AI续火花助手 (Douyin Sparks Helper)

抖音私信"火花"(连续聊天天数)维护插件。适配抖音 **40.7.0**(CFBundleVersion 407019,已对该版本二进制逐条复核,见 [docs/40.7.0-verify.md](docs/40.7.0-verify.md))、兼容 40.6.0(`com.ss.iphone.ugc.Aweme`),Relaxin/RootHide 越狱(roothide),兼容 Dopamine(rootless)。

当前版本 **v2.1.0** · 构建/发布走 [`liudubin/fudai-ci`](https://github.com/liudubin/fudai-ci)(Linux Theos,含公开镜像 Release,支持应用内检查更新)

## 功能全景

### 核心续火花
- **每日定时**:到点自动向目标好友/**群聊**发送 AI 生成的自然问候(默认 08:30,21:30 后顺延),每人每日一条,串行+随机间隔
- **AI 生成**:智谱 GLM / OpenAI / DeepSeek / Kimi / 通义千问一键预设,也可填任意 OpenAI 兼容接口;失败自动轮换内置兜底文案;避免与近期发过的内容重复;群聊单独口吻(能让人接话、不用@)
- **运行时校准**:首次在聊天里手动发一条消息即捕获发送上下文模板,之后全自动;群聊/单聊统一目标体系(uid/cid)
- **媒体火花(v2.1.0)**:逆向 IM 媒体上传管线——**图片/GIF 媒体库直发(无需打开聊天页,后台保活下也能发)**;AI 文本可转语音(TTS→AAC/m4a)发送;策略支持"媒体代替文本"或"文本后附加一条"
- **手动控制**:立即续火花、单发某目标、测试 AI 接入

### 界面(原生液态玻璃)
- **iOS 26+ 原生 `UIGlassEffect`**,深色染底保证可读;**液态玻璃/玻璃/磨砂三档材质切换**;旧系统回退原生超薄材质
- **卡片式布局**:进度卡(大数字+进度条)、玻璃选中胶囊分段(状态/目标/外观/设置/日志)
- **主题色**:8 预设 + 系统取色器,字体可选跟随;头部个人资料卡(自定义头像/昵称/专属ID/个性签名,头像支持 GIF)
- **悬浮球**:相册自定义图片/GIF 图标(ImageIO 逐帧解码,按帧率驱动,后台自动暂停)、大小 16~80 滑杆、透明背景、贴边吸附、长按菜单双入口(面板/直达设置/总开关)、打开面板自动隐藏
- **面板**:宽高实时调节、自定义背景图、5 种开合动画+速率、点外一下关闭、视频后台继续播放(不抢 key window)
- **成功提示浮条**:状态栏下方,可直接拖动或滑杆调节位置

### 实用工具
- 检查更新(GitHub 公开镜像 → 下载完调系统分享面板 → 更新包自动删除;域名白名单+https+拒私网校验)
- 配置备份/恢复(导出 JSON 分享 / 粘贴导入)
- 运行日志实时查看 + 一键复制;版本/作者/构建时间(北京时间)
- 后台保活(静音循环播放)+ 后台续火花;自愿捐赠入口

## 使用流程

1. 安装 deb(Relaxin 包),重启抖音,点悬浮球打开面板
2. **文本校准**:在任意好友聊天页手动发一条消息(一次即可)
3. **媒体校准(可选)**:在聊天里手动发一张图片(要用语音再发一条语音)
4. 面板设置页填 AI API Key,目标页从"最近聊天"添加好友/群
5. 打开总开关;发送需抖音前台(或开启后台保活+后台续火花)

## 工作原理(40.7.0 静态逆向验证)

| 抖音类/路由 | 用途 |
|---|---|
| `AWEIMMessageListViewModel setConversation:` | 会话捕获(uid/cid/昵称/secUid) |
| `AWEIMMessageListSendMessageComponent sendMessage:mentionUsers:customToast:enterFrom:` | 文本发送(参数 `AWEIMSendMessageContext`) |
| `AWEIMSendAttachmentController sendAttachmentMsgWithContext:completion:` | **媒体统一入口**(图片/GIF/语音,直收 conversationID) |
| `IESIMSendMediaInputContext` / `IESIMSendAudioInputContext` | 媒体上下文(fileType/tmpPath/messageContent;40.7.0 起**不含** duration/波形) |
| `AWEIMMessageAudioContent` | 语音内容模型(duration=毫秒 / averagePowerArr=波形),语音必须挂在这里 |
| `AWEIMMessageImageContent` | 图片内容模型(coverWidth/coverHeight/clientKey) |
| `snssdk1128://chat/message?uid=/cid=` | 打开单聊/群聊页 |

发送全部走抖音原生管道(等同手点);逐目标串行、随机间隔、每日一条。符号混淆(自有类零暴露),逆向工具链归档在 `tools/`(Mach-O ObjC 元数据解析 + 带注释反汇编)。

## 构建

本仓库只含 Tweak 源码,deb 的 arm64 dylib 必须在带 Theos 的机器上编译
(Windows 上无法出包:缺 clang + iOS SDK)。

Linux/macOS 本地:

```bash
export THEOS=~/theos
make package THEOS_PACKAGE_SCHEME=rootless     # Dopamine / 无根越狱
# 或 Relaxin / roothide 方案
make package
```

CI(与历史版本一致,产物 `sparkshelper-vX.Y.Z-Relaxin.deb`,私有仓 + 公开镜像双 Release):

```bash
git tag v2.x.x && git push origin v2.x.x
gh workflow run build-sparks.yml --repo liudubin/fudai-ci -f tag=v2.x.x
```

## 换版本前的必做校验

抖音改版会静默移除/搬走方法。改完代码先跑一遍:

```bash
python tools/verify_ipa.py /path/to/抖音_x.y.z.ipa
```

它不只查"类/方法名在不在",而是查**该方法是否由该类自身实现** —— 对继承来的
方法做 `%hook`,补丁会落到超类的 Method 上(等于 hook 全 App 的同类调用),
这正是 v2.15.0 里 `-init` 事故的成因。退出码非 0 即有断裂。

## 免责

仅供个人学习研究。自动发消息有触发抖音风控的风险,请控制目标数量与频率;后台保活会增加耗电;产生的一切后果自负。

## 插件授权（v2.14.6）

启动后自动向 https://fudai-auth.pages.dev/api/v1/check 注册/验证，产品为 `sparks`。
设置页显示授权状态及可复制的专属 ID；管理员在后台按该 ID 开通、续期或封禁。
只有验签成功且状态为 `ok` 的设备能使用插件发送功能，用户手动聊天不受影响。
后台状态在下次检查后生效（运行中每 10 分钟、回前台、设置页手动刷新；最短间隔 30 秒）。
网络故障允许本次进程内已验证授权最多 72 小时宽限，但不超过授权到期时间；重启后需联网。
现有协议使用与后台兼容的 HMAC 共享密钥，不能防止破解客户端提取密钥；更强的防伪需要后台迁移公钥签名。

验证：`cc -std=c11 -Wall -Wextra -Werror tests/license_policy.c -lm -o /tmp/license-policy && /tmp/license-policy`。
有后台源码时：`node tests/auth_contract.mjs /path/to/fudai-auth`（只用内存数据库和测试密钥）。
