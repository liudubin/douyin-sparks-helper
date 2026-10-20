//
//  SparksConfig.h
//  抖音AI续火花助手 —— 公共头:符号混淆 + 配置项 + 日志 + URL 校验
//
//  重要:本文件必须最先 #import(所有自有类的 @interface 声明之前),
//  否则 @interface 用原名而 @implementation 用混淆名会编译失败。
//  hook 的抖音类名(AWEIM*)是运行时字符串,不受此影响。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#pragma mark - 符号混淆(解包 dylib 验证:原类名出现次数应为 0)

#define SparksConfig        Sk0
#define SparksEngine        Sk1
#define SparksPanel         Sk2
#define SparksAI            Sk3
#define SparksHitWindow     Sk7
#define SparksGlassCard     Sk8
#define SparksCapsuleButton Sk9
#define SparksFieldRow      SkA
#define SparksInfoRow       SkB
#define SparksGifIconView   SkD
#define SparksGlassSeg      SkE
#define SparksKeepAlive     SkG
#define SparksTTSHelper      SkI
#define SparksStatusRow     SkJ
#define SparksSegTab        SkK

#pragma mark - 版本/构建时间(编译期注入)

extern NSString *SparksVersionString(void);
extern NSString *SparksBuildTimeString(void);
#define SPARKS_VER SparksVersionString()
#define SPARKS_BUILD SparksBuildTimeString()

#ifndef SPARKS_VERSION
#define SPARKS_VERSION "2.0.0"
#endif
#ifndef SPARKS_BUILD_TIME
#define SPARKS_BUILD_TIME ""
#endif

#pragma mark - URL 安全校验(仅 https,拒绝 localhost/环回/私有/保留地址)

extern BOOL SparksURLOK(NSURL *url);

#pragma mark - 配置单例接口

@interface SparksConfig : NSObject

+ (instancetype)shared;

// 主开关
@property (assign) BOOL master;
// 每日发送时间 HH:mm 或时间段 HH:mm-HH:mm(窗口内按日期确定性随机挑一时刻)
@property (copy) NSString *dailyTime;
// 解析后的今日实际发送时刻 HH:mm(时间段的当日抽样,含单点;reload 重算)
@property (copy) NSString *todayEffectiveTime;
// 相邻两个目标之间的基础间隔(秒)
@property (assign) double interval;

// AI 配置(OpenAI 兼容 /chat/completions)
@property (copy) NSString *aiURL;
@property (copy) NSString *aiKey;
@property (copy) NSString *aiModel;
@property (copy) NSString *aiExtra;   // 风格补充要求,拼进 user prompt

// 兜底文案(AI 失败时轮换使用)
@property (copy) NSArray<NSString *> *fallbacks;

// 目标好友:数组元素 {key(单聊=uid/群聊=cid), type(single/group), name, secUid}
@property (strong) NSMutableArray<NSDictionary *> *targets;
// 最近聊过的会话(自动捕获,面板选择用)
@property (strong) NSMutableArray<NSDictionary *> *recents;

// 发送模板(手动发一条消息时捕获)
// {class, enterFrom, userInfo, capturedAt}
@property (copy) NSDictionary *sendTemplate;
// 是否把捕获的 userInfo 透传给自动发送(默认关)
@property (assign) BOOL relayUserInfo;

// 发送记录:uid -> "yyyy-MM-dd"
@property (strong) NSMutableDictionary<NSString *, NSString *> *sentMap;
@property (copy) NSString *lastRunDay;
// 最近生成文本:uid -> [最近几条],用于去重
@property (strong) NSMutableDictionary<NSString *, NSArray<NSString *> *> *lastTexts;

// ── 悬浮球 ──
@property (assign) double ballSize;        // 16~80,默认 52(背景恒为透明)
@property (copy) NSString *ballIconPath;   // 自定义图标文件(图片/GIF),空=默认火焰

// ── 外观 ──
@property (assign) NSInteger materialMode; // 0 液态玻璃 1 玻璃 2 磨砂
@property (assign) NSInteger uiStyle;          // 界面风格 0 玻璃 1 控制台 2 目标卡片流 3 极简清单
@property (assign) BOOL noJump;                // 只后台发送:文本链路不通时改走语音/图片,绝不打开聊天页
@property (copy) NSString *accentHex;      // 主题色 HEX(空=默认火焰橙)
@property (assign) BOOL fontFollowsAccent;// 标题字体颜色跟随主题色
@property (assign) double panelW;          // 面板宽
@property (assign) double panelH;          // 面板高
@property (copy) NSString *panelBgPath;    // 面板自定义背景图(空=无)
@property (assign) NSInteger panelBackdrop; // 面板底衬 0关 1深色半透明 2玻璃材质
@property (assign) NSInteger animPreset;   // 开合动画 0弹簧 1缩放 2上浮 3侧滑 4淡入
@property (assign) double animSpeed;       // 开合速率 0.3~2.5(越大越快)

// ── 成功提示 ──
@property (assign) BOOL toastOn;           // 续火花结果浮条
@property (assign) double toastOffsetY;    // 距屏幕顶部偏移(外观页滑杆调节)
@property (assign) double cardAlpha;       // 卡片透明度 0.4~1.0(1=最实,越小越透)
@property (assign) BOOL time12h;           // 时间显示制式(YES=12小时制带上午/中午/下午/晚上)

// ── 个人资料(头部展示) ──
@property (copy) NSString *nickName;       // 昵称(空=默认标题,手动)
@property (copy) NSString *exclusiveId;    // (废弃)旧自定义ID,兼容保留不再编辑
@property (copy) NSString *authCode;       // 专属ID:授权后台自动分配(SPK-xxx),v2.14.4 起头部显示它
@property (copy) NSString *signature;      // 个性签名
@property (copy) NSString *avatarPath;     // 头像(图片/GIF,手动)
// ── 媒体火花 ──
@property (strong) NSMutableArray<NSString *> *mediaFiles;   // 媒体库文件路径(图片/GIF)
@property (assign) BOOL mediaOn;            // 启用媒体发送
@property (assign) BOOL mediaInstead;       // YES=代替文本 NO=文本外附加一条
@property (assign) BOOL ttsVoiceOn;         // AI 文本转语音发送(实验)
@property (copy) NSDictionary *mediaTpl;    // 图片/GIF 发送模板(校准捕获)
@property (copy) NSDictionary *audioTpl;    // 语音发送模板(校准捕获)

// ── 其他 ──
@property (copy) NSString *donateURL;      // 捐赠链接(https)
@property (assign) BOOL keepAlive;         // 后台保活(静音循环播放)
@property (assign) BOOL backgroundSend;    // 后台也续火花(依赖保活)
@property (assign) BOOL bgSilentSend;      // 后台静默:前台不跳聊天页,退后台自动发(v2.11)

- (void)reload;
- (void)save;
- (void)saveSoon;   // 防抖 0.5s 合并写盘

- (BOOL)sentToday:(NSString *)uid;
- (void)markSent:(NSString *)uid;
- (void)recordSentText:(NSString *)text forUid:(NSString *)uid;
- (NSArray<NSString *> *)recentTextsForUid:(NSString *)uid;

// 按目标 key 就地更新目标字典字段(命中后回调里改字段,自动防抖落盘)
// 目标级字段(v2.13):remark 备注名称/mode 0AI生成1独立文案/tprompt AI生成要求/
// dcount 每日条数/ttext 独立文案/voice 语音包语言码/imgOn 发送图片/imgPath 指定图/imgLock 锁定图片
- (void)updateTarget:(NSString *)key set:(void (^)(NSMutableDictionary *target))mut;

- (NSString *)nextFallbackForUid:(NSString *)uid;

- (UIColor *)accentColor;

#pragma mark - 备份/恢复(sparks.* 全量)

- (NSString *)exportBackupJSON;
- (BOOL)importBackupJSON:(NSString *)json;

@end

#pragma mark - 默认兜底文案

extern NSArray<NSString *> *SparksDefaultFallbacks(void);

#pragma mark - 简易日志(引擎内环形缓冲,面板展示)

extern void SparksLog(NSString *fmt, ...);
extern NSString *SparksLogSnapshot(void);
extern void SparksClearLogSnapshot(void);

#pragma mark - 引擎->面板 成功提示通知

extern NSString *const SparksToastNote;
