//
//  SparksEngine.h
//  调度 + 自动发送编排
//
#import "SparksConfig.h"

@interface SparksEngine : NSObject

+ (instancetype)shared;

/// Tweak 启动后调用:观察者 + 心跳定时器(仅 App 活跃时工作)
- (void)start;

/// hook AWEIMMessageListViewModel setConversation: 时上报(参数=会话模型,vm=VM 本体)
- (void)noteConversation:(id)conversation inVM:(id)vm;

/// hook AWEIMMessageListSendMessageComponent setDataService: 时上报(组件绑定会话)
- (void)noteComponent:(id)component;

/// hook sendMessage:mentionUsers:customToast:enterFrom: 时上报(捕获模板 + 记录)
- (void)observeSendWithContext:(id)ctx component:(id)component;

/// 当前聊天页会话 key(单聊=对方 uid,群聊=会话 cid;无则 nil)
@property (nonatomic, readonly) NSString *currentChatKey;

/// 手动触发一次(面板按钮);force=YES 忽略今日已发去重
- (void)runDailyNow:(BOOL)force;

/// 免跳页发送:先用 IM 服务按 uid/cid 反查会话(移植自第三方插件的 AWEIMModuleService 用法),
/// 拿到会话后走 AWEIMSendMessageController 直接投递。失败时调用方自行回退。
- (void)sendTextViaIM:(NSString *)text target:(NSDictionary *)target
           completion:(void (^)(BOOL ok))done;

/// 只后台模式兜底:文本链路不通时改发语音/图片(媒体通道后台可用),不打开聊天页
- (void)sendFallbackMediaForTarget:(NSDictionary *)target text:(NSString *)text
                        completion:(void (^)(BOOL ok))done;

/// 免跳页直发:有该会话的会话模型就走 AWEIMSendMessageController 直接投递,
/// 不打开聊天页;返回 NO 表示条件不具备,调用方应回退到打开聊天页的老路。
- (BOOL)sendTextWithoutPage:(NSString *)text target:(NSDictionary *)target;

/// hook LSIMChatListVM setConversations: 时整批缓存会话模型(免跳页直发的前置条件)
- (void)noteConversations:(NSArray *)list;

/// hook AWEIMSendMessageController 创建时回调:缓存 App 的实例供免跳页直发复用
- (void)noteSendController:(id)controller;

/// hook AWEIMSendMessageController 发送时回调:记录入参类型(免跳页按同类型构造)
- (void)noteControllerMessage:(id)message;

/// hook AWEIMSendMessageController 发送时回调(免跳页路径的发送回执)
- (void)noteControllerSend;

/// hook AWEIMSendAttachmentController 时上报(媒体模板校准)
- (void)observeAttachmentSend:(id)context;

/// 后台保活开关(静音循环播放;面板"后台"卡调用)
- (void)setKeepAliveEnabled:(BOOL)on;

/// 面板刷新回调(日志/状态变化时触发)
@property (nonatomic, copy) void (^onStateChange)(void);

@property (nonatomic, readonly) BOOL running;

/// 插件自动发送进行中(hook 侧用来区分,自动发的旧 userInfo 不回灌实时资料)
- (BOOL)isAutoSending;

@end
