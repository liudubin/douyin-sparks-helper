//
//  SparksEngine.m
//  每日定时:生成文本 -> 打开聊天页 -> 等组件就绪 -> 发送 -> 关页 -> 下一个
//
#import "SparksEngine.h"
#import "SparksAI.h"
#import "SparksLicense.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/ExtendedAudioFile.h>

// 前置声明:evalKeepAlive(引擎前段)用到,定义在文件后段
static NSString *SpTargetKey(NSDictionary *target);
static NSString *SpDisplayName(NSDictionary *target);
// HH:mm → 分钟(与 SparksConfig.m 同逻辑,独立小函数防跨文件依赖)
static NSInteger SpParseHM(NSString *s) {
    NSArray *hm = [s componentsSeparatedByString:@":"];
    if (hm.count != 2) return -1;
    NSInteger h = [hm[0] integerValue], m = [hm[1] integerValue];
    if (h < 0 || h > 23 || m < 0 || m > 59) return -1;
    return h * 60 + m;
}

// 抖音内部类(运行时取,避免链接依赖)
static Class ClsSendContext(void) { return NSClassFromString(@"AWEIMSendMessageContext"); }

// KVC 写字段的安全壳:字段在新版被拆到别的类上时,setValue:forKey: 会抛
// NSUnknownKeyException(不是返回 NO)。旧代码把整段组装放在一个 @try 里,
// 一个字段失效就整条发送失败且报"context 组装异常",极难定位。
// 这里逐字段兜底:失败的字段单独打日志,其余字段照常写入。
static BOOL SpSetKV(id obj, NSString *key, id value) {
    if (!obj || !key.length) return NO;
    @try {
        [obj setValue:value forKey:key];
        return YES;
    } @catch (NSException *e) {
        SparksLog(@"⚠️ %@ 无字段 %@(%@),已跳过", NSStringFromClass([obj class]), key, e.name);
        return NO;
    }
}

#pragma mark - 后台保活(静音循环播放)

@interface SparksKeepAlive : NSObject
+ (void)start;
+ (void)stop;
+ (BOOL)running;
+ (BOOL)recentlyFailing;   // 连续失败 ≥3 次:后台发送不再可靠
+ (NSString *)lastError;   // 最近一次失败原因(日志用)
@end

@implementation SparksKeepAlive {
    AVAudioPlayer *_player;
}
static SparksKeepAlive *_ka = nil;
static NSInteger _kaFailStreak = 0;      // 连续启动失败次数(降级判定)
static NSString *_kaLastError = nil;     // 最近一次失败原因(日志里要能看出毛病)

+ (BOOL)running {
    return _ka != nil && _ka->_player && _ka->_player.isPlaying;
}

// 连续 3 次起不来 = 后台锚点失效,继续按"后台可发"排程只会白等
+ (BOOL)recentlyFailing { return _kaFailStreak >= 3; }
+ (NSString *)lastError { return _kaLastError; }

+ (void)start {
    if ([self running]) return;
    _ka = [[SparksKeepAlive alloc] init];
    [_ka _begin];
}

+ (void)stop {
    if (_ka) {
        [_ka->_player stop];
        _ka = nil;
        SparksLog(@"后台保活已停止");
    }
}

- (void)_begin {
    NSURL *url = [self silentWavURL];
    if (!url) {
        _kaLastError = @"静音文件生成失败";
        SparksLog(@"⚠️ 保活:静音文件生成失败(Documents 不可写?)");
        [self _fail];
        return;
    }
    NSError *err = nil;
    _player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&err];
    if (!_player) {
        _kaLastError = err.localizedDescription ?: @"播放器创建失败";
        SparksLog(@"⚠️ 保活:播放器创建失败:%@", err.localizedDescription ?: @"");
        [self _fail];
        return;
    }
    _player.numberOfLoops = -1;
    _player.volume = 0.0;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *catErr = nil, *actErr = nil;
    @try {
        if (![session.category isEqualToString:AVAudioSessionCategoryPlayback]) {
            // MixWithOthers:别的 App 正在放音时别硬抢,否则激活失败→play 直接 NO
            [session setCategory:AVAudioSessionCategoryPlayback
                     withOptions:AVAudioSessionCategoryOptionMixWithOthers
                           error:&catErr];
        }
        [session setActive:YES error:&actErr];
    } @catch (NSException *e) {
        _kaLastError = [NSString stringWithFormat:@"音频会话异常:%@", e.name];
    }
    if ([_player play]) {
        _kaFailStreak = 0;
        _kaLastError = nil;
        SparksLog(@"🎧 后台保活已开启(静音循环)");
    } else {
        _kaLastError = [NSString stringWithFormat:@"play=NO(会话%@,激活错误=%@,分类错误=%@,其他音频%@)",
                        actErr ? @"激活失败" : @"已激活",
                        actErr.localizedDescription ?: @"-",
                        catErr.localizedDescription ?: @"-",
                        session.isOtherAudioPlaying ? @"占用中" : @"空闲"];
        SparksLog(@"⚠️ 保活:播放启动失败 %@", _kaLastError);
        [self _fail];
    }
}

// 失败也要计数:旧版直接把自己置空,心跳下轮重来但从不记得失败过几次
- (void)_fail {
    _kaFailStreak += 1;
    if (_kaFailStreak == 3) {
        SparksLog(@"⚠️ 保活连续失败 3 次(%@),后台发送不可靠,后续改走前台发送", _kaLastError ?: @"?");
    }
    _player = nil;
    _ka = nil;
}

// 生成 60 秒 8000Hz 16bit 单声道静音 WAV(60s 一循环,循环边界唤醒再减半)
- (NSURL *)silentWavURL {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *path = [dir stringByAppendingPathComponent:@"sparks_silence60.wav"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return [NSURL fileURLWithPath:path];
    }
    NSUInteger dataLen = 8000 * 2 * 60;
    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataLen];
    void (^appendStr)(NSString *) = ^(NSString *t) {
        [wav appendBytes:[t UTF8String] length:[t lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
    };
    void (^appendU32)(UInt32) = ^(UInt32 v) { [wav appendBytes:&v length:4]; };
    void (^appendU16)(UInt16) = ^(UInt16 v) { [wav appendBytes:&v length:2]; };
    appendStr(@"RIFF"); appendU32((UInt32)(36 + dataLen)); appendStr(@"WAVE");
    appendStr(@"fmt "); appendU32(16); appendU16(1); appendU16(1);
    appendU32(8000); appendU32(16000); appendU16(2); appendU16(16);
    appendStr(@"data"); appendU32((UInt32)dataLen);
    [wav increaseLengthBy:dataLen];
    if ([wav writeToFile:path atomically:YES]) {
        return [NSURL fileURLWithPath:path];
    }
    return nil;
}

@end

#pragma mark - TTS 语音合成(AVSpeechSynthesizer -> ExtAudioFile AAC/m4a)

@interface SparksTTSHelper : NSObject
// lang=语音包语言码(zh-CN/zh-HK/zh-TW 等),空=默认普通话
+ (void)synthesize:(NSString *)text voice:(NSString *)lang completion:(void (^)(NSString *path, double duration, NSString *error))done;
@end

// 存活池:write:toBuffer: 异步回调期间必须强持有助手,
// 否则 run: 返回即释放 → 合成中断 → completion 永不回调 → 发送链卡死
static NSMutableSet *SpTTSPool(void) {
    static NSMutableSet *pool;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pool = [NSMutableSet set]; });
    return pool;
}

@implementation SparksTTSHelper {
    AVSpeechSynthesizer *_synth;
}

+ (void)synthesize:(NSString *)text voice:(NSString *)lang completion:(void (^)(NSString *, double, NSString *))done {
    dispatch_async(dispatch_get_main_queue(), ^{
        SparksTTSHelper *h = [[SparksTTSHelper alloc] init];
        [SpTTSPool() addObject:h];
        [h run:text voice:lang completion:^(NSString *path, double duration, NSString *error) {
            [SpTTSPool() removeObject:h];
            if (done) done(path, duration, error);
        }];
    });
}

- (void)run:(NSString *)text voice:(NSString *)lang completion:(void (^)(NSString *, double, NSString *))done {
    _synth = [[AVSpeechSynthesizer alloc] init];
    AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text ?: @""];
    u.voice = [AVSpeechSynthesisVoice voiceWithLanguage:lang.length ? lang : @"zh-CN"];
    u.rate = AVSpeechUtteranceDefaultSpeechRate;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"sparks_tts.m4a"];
    NSURL *url = [NSURL fileURLWithPath:path];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

    __block ExtAudioFileRef file = NULL;
    __block double frames = 0;
    __block double sampleRate = 0;
    __block BOOL failed = NO;
    __weak typeof(self) ws = self;
    typeof(self) strongSelf = self;   // synth 回调期间保活(self 由 synth 的 block 持有即可)
    (void)strongSelf;

    void (^bufferHandler)(AVAudioBuffer *) = ^(AVAudioBuffer *buffer) {
        if (failed) return;
        if (!buffer) {
            // nil buffer = 合成结束
            if (file) {
                ExtAudioFileDispose(file);
                double dur = sampleRate > 0 ? frames / sampleRate : 0;
                if (dur >= 1.0) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (done) done(path, dur, nil);
                    });
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (done) done(nil, 0, @"合成时长过短");
                    });
                }
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (done) done(nil, 0, @"合成失败(无音频数据)");
                });
            }
            return;
        }
        AVAudioPCMBuffer *pb = (AVAudioPCMBuffer *)buffer;
        if (pb.frameLength == 0) return;
        if (!file) {
            sampleRate = pb.format.sampleRate;
            AudioStreamBasicDescription outDesc;
            memset(&outDesc, 0, sizeof(outDesc));
            outDesc.mFormatID = kAudioFormatMPEG4AAC;
            outDesc.mSampleRate = sampleRate;
            outDesc.mChannelsPerFrame = (UInt32)MAX(1, pb.format.channelCount);
            outDesc.mFramesPerPacket = 1024;
            OSStatus st = ExtAudioFileCreateWithURL((__bridge CFURLRef)url, kAudioFileM4AType,
                                                     &outDesc, NULL, kAudioFileFlags_EraseFile, &file);
            if (st != noErr || !file) {
                failed = YES;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (done) done(nil, 0, [NSString stringWithFormat:@"m4a 创建失败(%d)", (int)st]);
                });
                return;
            }
            ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                    sizeof(AudioStreamBasicDescription), pb.format.streamDescription);
        }
        OSStatus w = ExtAudioFileWrite(file, pb.frameLength, pb.audioBufferList);
        if (w == noErr) frames += pb.frameLength;
    };
    SEL writeSel = NSSelectorFromString(@"write:toBuffer:");
    if ([_synth respondsToSelector:writeSel]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(_synth, writeSel, u, bufferHandler);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (done) done(nil, 0, @"系统不支持 TTS 写入");
        });
    }
    (void)ws;
}

@end

@interface SparksEngine ()
@property (nonatomic, copy) NSString *currentChatKey;   // 单聊=对方 uid,群聊=会话 cid
@property (nonatomic, copy) NSString *currentChatType;  // single / group
@property (nonatomic, copy) NSString *currentChatName;
@property (nonatomic, strong) NSMapTable<NSString *, id> *components; // key -> weak 组件
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL inAutoSend;   // 区分插件自动发 / 用户手动发
@property (nonatomic, copy) void (^sendAckProbe)(void);   // 自动发送后的回执探针(hook 到真实发送时触发)
// key -> 会话模型(AWEIMMessageConversation)。免跳页直发需要它:底层
// AWEIMSendMessageController 的入参是"上下文 + 会话对象",而会话对象只能从
// setConversation: 钩子里拿到。没缓存过就退回打开聊天页那条老路。
@property (nonatomic, strong) NSMutableDictionary *conversations;
@property (nonatomic, copy) NSString *pollingKey;   // 正在等待就绪的目标(诊断日志窗口)
@property (nonatomic, strong) id currentChatVM;   // 最近绑定的聊天页 VM 本体(组件中心兜底用)
@property (nonatomic, strong) id pendingComponent;   // 会话未绑定时先到的发送组件(挂起等绑定)
@property (nonatomic, assign) BOOL deferredNoteShown;   // 前台静默等待提示只打一次
@property (nonatomic, assign) BOOL started;
// v2.15:等页面和等组件分开计时(旧版共用 20s 预算,页面被系统吞掉就白等)
@property (nonatomic, assign) NSTimeInterval pollStartAt;
@property (nonatomic, assign) NSTimeInterval pageOpenAt;
@property (nonatomic, assign) NSTimeInterval lastInputVCTryAt;
@property (nonatomic, assign) NSTimeInterval lastInputVCLogAt;   // 直发失败原因节流(重试期间别刷屏)
@property (nonatomic, assign) NSInteger routeResendCount;
// v2.15:本轮失败目标退避补发(不再指望"整轮重跑"的运气)
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *retryQueue;
@property (nonatomic, strong) NSArray<NSDictionary *> *activeTargets;   // 常规=cfg.targets,补发=失败队列
@property (nonatomic, assign) NSInteger retryPass;
@property (nonatomic, assign) BOOL keepAliveBroken;   // 保活连续失败:不再依赖后台发送
@end

@implementation SparksEngine

+ (instancetype)shared {
    static SparksEngine *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[SparksEngine alloc] init]; });
    return s;
}

- (BOOL)isAutoSending {
    return self.inAutoSend;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _components = [NSMapTable strongToWeakObjectsMapTable];
        _conversations = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - 启动

- (void)start {
    if (_started) return;
    _started = YES;
    [SparksLicense start];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    __weak typeof(self) ws = self;
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil
                 usingBlock:^(NSNotification *n) {
        [ws heartbeat];
    }];
    // 退后台瞬间立即评估保活+心跳:前台静默等待的发送在此刻立刻执行(页面后台打开不可见)
    [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil
                 usingBlock:^(NSNotification *n) {
        typeof(self) s = ws;
        if (!s) return;
        [s evalKeepAliveAllowStart:YES];   // 通知时 state 仍是 Active,需放行
    }];
    // 进入后台完成态(此时 state 已是 Background):静默等待的发送立刻执行,不等 60s 心跳
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil
                 usingBlock:^(NSNotification *n) {
        typeof(self) s = ws;
        if (s) [s heartbeat];
    }];
    [nc addObserverForName:SparksLicenseChangedNotification object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(NSNotification *n) {
        [ws evalKeepAlive];
        if (ws.onStateChange) ws.onStateChange();
    }];
    [self armTimer];
    [self evalKeepAlive];
    SparksLog(@"引擎启动 v%@ (build %@)", SPARKS_VER, SPARKS_BUILD);
    if (!self.config.sendTemplate) {
        SparksLog(@"尚未校准:先在任意好友聊天页手动发一条消息");
    }
}

- (SparksConfig *)config { return [SparksConfig shared]; }

- (void)armTimer {
    __weak typeof(self) ws = self;
    // 发热四轮:今日目标全发完→心跳降到 3 分钟(只剩跨日重置要跑);否则保持 60s 发送精度
    double interval = 60;
    SparksConfig *cfgNow = self.config;
    BOOL anyLeft = NO;
    for (NSDictionary *t in cfgNow.targets) {
        if (![cfgNow sentToday:SpTargetKey(t)]) { anyLeft = YES; break; }
    }
    if (!anyLeft) interval = 180;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) s = ws;
        if (!s) return;
        [s heartbeat];
        [s armTimer];   // 单次触发链:关闭开关/退进程自然停
    });
}

- (void)heartbeat {
    // 发热优化:心跳只做计划检查,不刷 UI;面板刷新由真实事件(发送/开关/校准)触发,
    // 配合面板侧状态签名去重,避免每 60s 整树重建
    [self evalKeepAlive];
    UIApplicationState st = UIApplication.sharedApplication.applicationState;
    if (st == UIApplicationStateActive) {
        [self checkSchedule];
    } else if (self.config.keepAlive) {
        // 后台保活:进程仍活,定时器继续跑
        [self checkSchedule];
    }
}

// 按需保活(发热修复:旧版一旦开启就全天循环静音音频):
// 仅当【非前台 + 开关齐 + 今日仍有未发目标】才开;前台/发完/停用立即停。
// 前台进程天然活着不需要音频;发完当天不再唤醒;总开关关闭即静默挂起。
- (void)evalKeepAlive {
    [self evalKeepAliveAllowStart:(UIApplication.sharedApplication.applicationState != UIApplicationStateActive)];
}

- (void)evalKeepAliveAllowStart:(BOOL)allowStart {
    SparksConfig *cfg = self.config;
    self.keepAliveBroken = [SparksKeepAlive recentlyFailing];   // 起不来就别再假装后台可发
    BOOL wanted = [SparksLicense isActive] && cfg.keepAlive && cfg.backgroundSend && cfg.master && allowStart;
    if (wanted) {
        wanted = NO;
        for (NSDictionary *t in cfg.targets) {
            if (![cfg sentToday:SpTargetKey(t)]) { wanted = YES; break; }
        }
    }
    if (wanted) {
        [SparksKeepAlive start];
    } else if ([SparksKeepAlive running]) {
        [SparksKeepAlive stop];
        SparksLog(@"🧊 保活按需休止(前台/已发完/已停用)");
    }
}

- (void)checkSchedule {
    if (self.running) return;
    SparksConfig *cfg = self.config;
    if (!cfg.master || ![SparksLicense isActive]) return;
    if (!cfg.targets.count) return;
    if (![cfg.sendTemplate isKindOfClass:[NSDictionary class]]) return;

    NSDate *now = [NSDate date];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *comp = [cal components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:now];

    // todayEffectiveTime=单点或时间段当日抽样(config reload/save 时重算),非法时兜底 08:30
    NSInteger schedMin = SpParseHM(cfg.todayEffectiveTime ?: @"");
    if (schedMin < 0) schedMin = SpParseHM(@"08:30");
    NSInteger nowMin = comp.hour * 60 + comp.minute;
    if (nowMin < schedMin) return;          // 还没到点
    if (nowMin > 21 * 60 + 30) return;      // 太晚不打扰(超过 21:30 顺延明天)
    NSString *today = [self todayString];
    if ([cfg.lastRunDay isEqualToString:today]) return;

    // 有目标今天没发过才跑
    BOOL anyLeft = NO;
    for (NSDictionary *t in cfg.targets) {
        if (![cfg sentToday:SpTargetKey(t)]) { anyLeft = YES; break; }
    }
    if (!anyLeft) {
        cfg.lastRunDay = today;
        [cfg saveSoon];
        return;
    }
    // 后台静默(v2.11):前台不跳聊天页,等退后台的瞬间再发(页面在后台打开不可见)
    // 需保活+后台发送齐备,否则降级为普通前台发送(否则 App 挂起后心跳死掉永远发不出)
    if (self.keepAliveBroken && cfg.bgSilentSend) {
        // 保活起不来 → 退后台进程会被挂起 → 静默等待等于今天不发
        SparksLog(@"⚠️ 保活连续失败(%@),取消前台静默等待,本轮直接前台发送",
                  [SparksKeepAlive lastError] ?: @"?");
    } else if (cfg.bgSilentSend && cfg.keepAlive && cfg.backgroundSend
        && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        if (!self.deferredNoteShown) {
            self.deferredNoteShown = YES;
            SparksLog(@"😴 前台静默等待:退到后台后自动发送(不跳聊天页)");
        }
        return;   // 心跳每 60s 重查;WillResignActive 瞬间也会触发 heartbeat 立即发
    }
    self.deferredNoteShown = NO;
    SparksLog(@"⏰ 到达计划时间 %@,开始今日续火花", cfg.todayEffectiveTime ?: cfg.dailyTime);
    [self runDailyNow:NO];
}

- (NSString *)todayString {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"yyyy-MM-dd"];
    return [df stringFromDate:[NSDate date]];
}

#pragma mark - hook 上报

- (void)noteConversation:(id)conv inVM:(id)vm {
    if (!vm) return;
    NSString *uid = nil, *name = nil, *secUid = nil, *cid = nil;
    if ([conv respondsToSelector:@selector(peerUserID)]) {
        id v = [conv performSelector:@selector(peerUserID)];
        if ([v isKindOfClass:[NSString class]]) uid = v;
        else if ([v respondsToSelector:@selector(longLongValue)]) uid = [NSString stringWithFormat:@"%lld", [v longLongValue]];
    }
    if ([conv respondsToSelector:@selector(conversationID)]) {
        id v = [conv performSelector:@selector(conversationID)];
        if ([v isKindOfClass:[NSString class]]) cid = v;
        else if ([v respondsToSelector:@selector(longLongValue)]) cid = [NSString stringWithFormat:@"%lld", [v longLongValue]];
    }
    if ([conv respondsToSelector:@selector(peerSecUserID)]) {
        id v = [conv performSelector:@selector(peerSecUserID)];
        if ([v isKindOfClass:[NSString class]]) secUid = v;
    }
    if ([conv respondsToSelector:@selector(name)]) {
        id v = [conv performSelector:@selector(name)];
        if ([v isKindOfClass:[NSString class]]) name = v;
    }

    // 统一 key:单聊=uid,群聊(无对方 uid 但有会话 id)=cid
    NSString *key = nil, *type = nil;
    if (uid.length) {
        key = uid;
        type = @"single";
    } else if (cid.length) {
        key = cid;
        type = @"group";
    }
    self.currentChatKey = key;
    self.currentChatType = type;
    self.currentChatName = name;
    self.currentChatVM = vm;
    // 存下会话模型本体:免跳页直发时直接复用,不必再打开聊天页
    if (key.length && conv) {
        @synchronized (self.conversations) { self.conversations[key] = conv; }
    }
    // 轮询窗口内打印绑定事件:定位"聊天页就绪超时"到底断在会话绑定还是组件注册
    if (key.length && self.pollingKey.length) {
        SparksLog(@"📥 会话绑定:%@[%@] 轮询目标:%@", name ?: key, type, self.pollingKey);
    }
    // 先到的组件补注册(40.7.0 组件中心注册可能早于会话绑定)
    if (key.length && self.pendingComponent) {
        [self.components setObject:self.pendingComponent forKey:key];
        self.pendingComponent = nil;
        if (self.pollingKey.length) SparksLog(@"🔗 挂起组件补注册:%@", key);
    }
    // 组件兜底:路由打开的页面 setDataService: 可能不触发,直接从 VM 组件中心取发送组件
    if (key.length) [self registerComponentFromVM:vm];

    if (key.length) {
        [self recordRecent:@{@"key": key,
                             @"type": type,
                             @"cid": cid ?: @"",
                             @"name": name ?: key,
                             @"secUid": secUid ?: @""}];
    }
}

- (void)recordRecent:(NSDictionary *)info {
    SparksConfig *cfg = self.config;
    NSString *key = info[@"key"];
    for (NSDictionary *old in [cfg.recents copy]) {
        if ([old[@"key"] isEqualToString:key] ||
            (![old[@"key"] isKindOfClass:[NSString class]] && [old[@"uid"] isEqualToString:key])) {
            NSMutableDictionary *m = [old mutableCopy];
            m[@"name"] = info[@"name"];
            m[@"key"] = key;
            m[@"type"] = info[@"type"];
            if (((NSString *)info[@"cid"]).length) m[@"cid"] = info[@"cid"];
            if (((NSString *)info[@"secUid"]).length) m[@"secUid"] = info[@"secUid"];
            [cfg.recents removeObject:old];
            [cfg.recents insertObject:m atIndex:0];
            [cfg saveSoon];
            return;
        }
    }
    [cfg.recents insertObject:[info mutableCopy] atIndex:0];
    if (cfg.recents.count > 30) {
        [cfg.recents removeObjectsInRange:NSMakeRange(30, cfg.recents.count - 30)];
    }
    [cfg saveSoon];
}

- (void)noteComponent:(id)component {
    if (!component) return;
    NSString *key = self.currentChatKey;
    if (key.length) {
        [self.components setObject:component forKey:key];
        if (self.pollingKey.length) {
            SparksLog(@"🔗 组件注册:%@ 轮询目标:%@", key, self.pollingKey);
        }
    } else {
        // 会话还没绑定(组件先到):挂起,绑定后立即补注册
        self.pendingComponent = component;
        if (self.pollingKey.length) {
            SparksLog(@"🔗 组件先到(会话未绑定),挂起等待:%@", component);
        }
    }
}

// 组件中心兜底:会话 VM.componentCenter.components 数组里找 AWEIMMessageListSendMessageComponent
// (40.6.0 验证;setDataService: 钩子不触发时从此路注册,轮询期也定时重试)
- (void)registerComponentFromVM:(id)vm {
    if (!vm) return;
    @try {
        Class compCls = NSClassFromString(@"AWEIMMessageListSendMessageComponent");
        if (!compCls) {
            if (self.pollingKey.length) SparksLog(@"❗ 发送组件类不存在——抖音已升级,插件需适配新版");
            return;
        }
        if (![vm respondsToSelector:@selector(componentCenter)]) {
            if (self.pollingKey.length) SparksLog(@"❗ 会话 VM 无 componentCenter——抖音已升级,插件需适配新版");
            return;
        }
        id center = [vm performSelector:@selector(componentCenter)];
        if (!center || ![center respondsToSelector:@selector(components)]) {
            if (self.pollingKey.length) {
                SparksLog(@"⚠️ VM 组件中心不可用(center=%@,components=%@)",
                          center ? @"有" : @"nil",
                          [center respondsToSelector:@selector(components)] ? @"可读" : @"不可读");
            }
            return;
        }
        NSArray *comps = [center performSelector:@selector(components)];
        if (![comps isKindOfClass:[NSArray class]] || !comps.count) {
            if (self.pollingKey.length) {
                SparksLog(@"⚠️ 组件中心数组为空(%@)", comps ? @"空数组" : @"nil");
            }
            return;
        }
        for (id c in comps) {
            if ([c isKindOfClass:compCls]) {
                if (self.currentChatKey.length) {
                    [self.components setObject:c forKey:self.currentChatKey];
                    if (self.pollingKey.length) {
                        SparksLog(@"🔗 组件兜底注册(组件中心):%@ 共%lu个组件",
                                  self.currentChatKey, (unsigned long)comps.count);
                    }
                }
                return;
            }
        }
        if (self.pollingKey.length) {
            // 只报"共 N 个"没法判断是组件没建还是类名变了,把清单一起打出来
            NSMutableArray *names = [NSMutableArray arrayWithCapacity:comps.count];
            for (id c in comps) [names addObject:NSStringFromClass([c class]) ?: @"(匿名)"];
            SparksLog(@"⚠️ 组件中心无发送组件(共%lu个):%@",
                      (unsigned long)comps.count, [names componentsJoinedByString:@" | "]);
        }
    } @catch (NSException *e) {
        if (self.pollingKey.length) SparksLog(@"⚠️ 组件中心兜底异常:%@", e.name);
    }
}

- (void)observeSendWithContext:(id)ctx component:(id)component {
    if (self.inAutoSend) {
        SparksLog(@"🤖 自动发送已提交(key=%@)", self.currentChatKey);
        // 回执探针:hook 链路真实收到这次提交才触发(区别于"调用 sendMessage 成功")
        if (self.sendAckProbe) {
            void (^probe)(void) = self.sendAckProbe;
            self.sendAckProbe = nil;
            dispatch_async(dispatch_get_main_queue(), probe);
        }
        return;
    }
    // 发送瞬间组件与会话的对应关系最准,顺手登记
    if (component && self.currentChatKey.length) {
        [self.components setObject:component forKey:self.currentChatKey];
    }
    // 用户手动发消息 -> 捕获模板
    NSString *cls = ctx ? NSStringFromClass([ctx class]) : @"(nil)";
    NSMutableDictionary *tpl = [NSMutableDictionary dictionary];
    tpl[@"class"] = cls;
    tpl[@"capturedAt"] = [self todayString];
    if ([ctx respondsToSelector:@selector(enterFrom)]) {
        id ef = [ctx performSelector:@selector(enterFrom)];
        if ([ef isKindOfClass:[NSString class]] && ((NSString *)ef).length) tpl[@"enterFrom"] = ef;
    }
    if ([ctx respondsToSelector:@selector(userInfo)]) {
        id ui = [ctx performSelector:@selector(userInfo)];
        if ([ui isKindOfClass:[NSDictionary class]]) tpl[@"userInfo"] = ui;
    }
    BOOL hadTpl = self.config.sendTemplate != nil;
    self.config.sendTemplate = tpl;
    [self.config saveSoon];
    if (!hadTpl) {
        SparksLog(@"✅ 校准完成:捕获发送上下文类 %@", cls);
        if (self.onStateChange) self.onStateChange();
    }
}

#pragma mark - 媒体(图片/GIF/语音)校准捕获与直发

// hook AWEIMSendAttachmentController sendAttachmentMsgWithContext: 时上报
- (void)observeAttachmentSend:(id)ctx {
    if (self.inAutoSend) {
        SparksLog(@"🤖 媒体自动发送已提交");
        return;
    }
    if (![ctx isKindOfClass:[NSObject class]]) return;
    NSString *cls = NSStringFromClass([ctx class]);
    NSMutableDictionary *tpl = [NSMutableDictionary dictionary];
    tpl[@"class"] = cls;
    id ft = nil;
    @try { ft = [ctx valueForKey:@"fileType"]; } @catch (NSException *e) {}
    if ([ft isKindOfClass:[NSNumber class]]) tpl[@"fileType"] = ft;
    id dur = nil;
    @try { dur = [ctx valueForKey:@"duration"]; } @catch (NSException *e) {}
    if ([dur isKindOfClass:[NSNumber class]]) tpl[@"duration"] = dur;
    id mt = nil;
    @try { mt = [ctx valueForKey:@"messageType"]; } @catch (NSException *e) {}
    if ([mt isKindOfClass:[NSNumber class]]) tpl[@"messageType"] = mt;
    id mc = nil;
    @try { mc = [ctx valueForKey:@"messageContent"]; } @catch (NSException *e) {}
    if ([mc respondsToSelector:@selector(contentDictionary)]) {
        id dict = [mc performSelector:@selector(contentDictionary)];
        if ([dict isKindOfClass:[NSDictionary class]]) {
            tpl[@"contentClass"] = NSStringFromClass([mc class]);
            tpl[@"contentDict"] = dict;
        }
    }

    BOOL isAudio = [cls containsString:@"Audio"];
    SparksConfig *cfg = self.config;
    if (isAudio) {
        if (!cfg.audioTpl) SparksLog(@"✅ 语音发送已校准(fileType=%@)", ft);
        cfg.audioTpl = tpl;
    } else {
        if (!cfg.mediaTpl) SparksLog(@"✅ 图片/GIF 发送已校准(fileType=%@)", ft);
        cfg.mediaTpl = tpl;
    }
    [cfg saveSoon];
    if (self.onStateChange) self.onStateChange();
}

// 媒体直发:本地文件 + 校准模板重建 context,无需打开聊天页(后台可用)
- (void)sendMediaFile:(NSString *)path
                audio:(BOOL)audio
             duration:(double)duration
               target:(NSDictionary *)target
            completion:(void (^)(BOOL ok, NSString *err))done {
    if (![SparksLicense isActive]) {
        if (done) done(NO, [SparksLicense statusText]);
        return;
    }
    SparksConfig *cfg = self.config;
    NSDictionary *tpl = audio ? cfg.audioTpl : cfg.mediaTpl;
    if (![tpl isKindOfClass:[NSDictionary class]]) {
        if (done) done(NO, audio ? @"语音未校准(先在聊天里手动发一条语音)" : @"图片未校准(先在聊天里手动发一张图)");
        return;
    }
    Class ctxCls = NSClassFromString(tpl[@"class"]);
    Class ctrlCls = NSClassFromString(@"AWEIMSendAttachmentController");
    if (!ctxCls || !ctrlCls) {
        if (done) done(NO, @"内部类缺失");
        return;
    }
    NSString *cid = target[@"cid"];
    if (![cid isKindOfClass:[NSString class]] || !cid.length) {
        if (SpTargetIsGroup(target)) cid = SpTargetKey(target);
    }
    if (![cid isKindOfClass:[NSString class]] || !cid.length) {
        if (done) done(NO, @"缺少会话ID:先手动打开一次该聊天页");
        return;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (done) done(NO, @"媒体文件不存在");
        return;
    }

    id ctx = [[ctxCls alloc] init];
    if (!ctx) {
        if (done) done(NO, @"context 创建失败");
        return;
    }
    @try {
        SpSetKV(ctx, @"conversationID", cid);
        SpSetKV(ctx, @"tmpPath", path);
        if (audio) {
            // 40.7.0 复核:IESIMSendAudioInputContext 没有 duration / averagePowerArr
            // (那是 AWEIMMessageAudioContent 的字段,见 docs/40.7.0-verify.md)。
            // 直接写在 ctx 上会抛 NSUnknownKeyException,整条语音因此发不出去。
            // 正确姿势:时长(毫秒)+ 波形挂到 messageContent 这个音频内容模型上。
            NSInteger points = MAX(5, (NSInteger)(duration / 0.2));
            NSMutableArray *powers = [NSMutableArray array];
            for (NSInteger i = 0; i < points; i++) {
                [powers addObject:@(0.25 + (double)(arc4random() % 50) / 100.0)];
            }
            Class acCls = NSClassFromString(@"AWEIMMessageAudioContent");
            if (acCls) {
                id ac = [[acCls alloc] init];
                if (duration > 0) SpSetKV(ac, @"duration", @((long long)(duration * 1000.0)));   // 毫秒
                SpSetKV(ac, @"averagePowerArr", powers);
                SpSetKV(ctx, @"messageContent", ac);
            } else {
                // 老版本兜底:字段原本就在 ctx 自己身上
                if (duration > 0) SpSetKV(ctx, @"duration", @(duration));
                SpSetKV(ctx, @"averagePowerArr", powers);
            }
            id mt = tpl[@"messageType"];
            if ([mt isKindOfClass:[NSNumber class]]) SpSetKV(ctx, @"messageType", mt);
        } else {
            NSDictionary *cd = tpl[@"contentDict"];
            if ([cd isKindOfClass:[NSDictionary class]]) {
                Class cCls = NSClassFromString(tpl[@"contentClass"]) ?: NSClassFromString(@"AWEIMMessageImageContent");
                if (cCls) {
                    NSMutableDictionary *dict = [cd mutableCopy];
                    [dict removeObjectForKey:@"clientKey"];
                    [dict removeObjectForKey:@"md5"];
                    [dict removeObjectForKey:@"resourceUrl"];
                    id mc = ((id (*)(id, SEL, id))objc_msgSend)([cCls alloc], @selector(initWithDictionary:), dict);
                    if (mc) {
                        UIImage *img = [UIImage imageWithContentsOfFile:path];
                        if (img) {
                            CGFloat maxSide = MAX(img.size.width, img.size.height);
                            CGFloat scale = MIN(1.0, 1200.0 / (maxSide > 0 ? maxSide : 1));
                            SpSetKV(mc, @"coverWidth", @((NSInteger)(img.size.width * scale)));
                            SpSetKV(mc, @"coverHeight", @((NSInteger)(img.size.height * scale)));
                        }
                        SpSetKV(mc, @"clientKey", [NSString stringWithFormat:@"sparks_%u", arc4random()]);
                        SpSetKV(ctx, @"messageContent", mc);
                    }
                }
            }
            id ft = tpl[@"fileType"];
            if ([ft isKindOfClass:[NSNumber class]]) SpSetKV(ctx, @"fileType", ft);
        }
    } @catch (NSException *e) {
        if (done) done(NO, [NSString stringWithFormat:@"context 组装异常:%@", e.reason]);
        return;
    }

    id ctrl = [[ctrlCls alloc] init];
    self.inAutoSend = YES;
    SparksLog(@"📤 直发%@:%@(%@)", audio ? @"语音" : @"图片", SpDisplayName(target), path.lastPathComponent);
    ((void (*)(id, SEL, id, id))objc_msgSend)(ctrl, @selector(sendAttachmentMsgWithContext:completion:), ctx, nil);
    self.inAutoSend = NO;

    [self.config markSent:SpTargetKey(target)];
    if (self.onStateChange) self.onStateChange();
    [self scheduleCloseChatIfSilent];
    [[NSNotificationCenter defaultCenter] postNotificationName:SparksToastNote object:nil
                                                      userInfo:@{@"text": [NSString stringWithFormat:@"🔥 已给 %@ 发送%@",
                                                                            SpDisplayName(target),
                                                                            audio ? @"语音" : @"图片"]}];
    if (done) done(YES, nil);
}

#pragma mark - 保活开关(面板调用)

- (void)setKeepAliveEnabled:(BOOL)on {
    self.config.keepAlive = on;
    [self.config saveSoon];
    // 不再直接起播:交给 evalKeepAlive 按需判定(后台+开关齐+今日未发完才开)
    [self evalKeepAlive];
    if (on) SparksLog(@"保活已允许(按需:仅后台且今日未发完时运行)");
}

#pragma mark - 主流程

- (void)runDailyNow:(BOOL)force {
    if (![SparksLicense isActive]) {
        SparksLog(@"⚠️ 无法发送：%@", [SparksLicense statusText]);
        [SparksLicense checkNow];
        return;
    }
    if (self.running) {
        SparksLog(@"已有任务在执行中");
        return;
    }
    SparksConfig *cfg = self.config;
    if (!cfg.targets.count) {
        SparksLog(@"⚠️ 目标列表为空,先到面板添加好友");
        return;
    }
    if (!cfg.sendTemplate) {
        SparksLog(@"⚠️ 尚未校准:先在任意好友聊天页手动发一条消息");
        return;
    }
    self.running = YES;
    self.activeTargets = cfg.targets;
    self.retryQueue = [NSMutableArray array];
    self.retryPass = 0;
    cfg.lastRunDay = [self todayString];
    // 立即落盘:saveSoon 会延迟 0.5s,期间面板 reload 读到旧 lastRunDay 会再开一整轮
    [cfg save];
    SparksLog(@"🚀 开始续火花:%lu 个目标(强制=%d)", (unsigned long)cfg.targets.count, force);
    [self sendNextFromIndex:0 round:0 force:force];
    if (self.onStateChange) self.onStateChange();
}

// 目标统一 key(单聊=uid,群聊=cid);旧版单聊目标无 key 字段时回退 uid
static NSString *SpTargetKey(NSDictionary *target) {
    NSString *k = target[@"key"];
    if (![k isKindOfClass:[NSString class]] || !k.length) k = target[@"uid"];
    return k;
}

static BOOL SpTargetIsGroup(NSDictionary *target) {
    return [target[@"type"] isEqualToString:@"group"];
}

// 显示名:备注(v2.13 单独设置)>原始昵称>key,日志/toast/AI 称呼统一用它
static NSString *SpDisplayName(NSDictionary *target) {
    NSString *r = [target[@"remark"] isKindOfClass:[NSString class]] ? target[@"remark"] : nil;
    if (r.length) return r;
    NSString *n = [target[@"name"] isKindOfClass:[NSString class]] ? target[@"name"] : nil;
    if (n.length) return n;
    return SpTargetKey(target);
}

- (void)sendNextFromIndex:(NSUInteger)idx round:(NSInteger)round force:(BOOL)force {
    if (![SparksLicense isActive]) {
        self.running = NO;
        SparksLog(@"⚠️ 续火花已停止：%@", [SparksLicense statusText]);
        [self evalKeepAlive];
        if (self.onStateChange) self.onStateChange();
        return;
    }
    SparksConfig *cfg = self.config;
    NSArray *list = self.activeTargets ?: cfg.targets;   // 补发轮只跑失败队列
    if (idx >= list.count) {
        // v2.15:本轮有目标没发出去 → 退避后自动补发,不再等"后台整轮重跑"这种运气
        if (self.retryPass < 3 && self.retryQueue.count) {
            [self scheduleRetryPass];
            return;   // running 保持 YES,期间心跳不会另开一轮
        }
        self.running = NO;
        self.activeTargets = nil;
        NSUInteger done = 0;
        NSMutableArray *missing = [NSMutableArray array];
        for (NSDictionary *t in cfg.targets) {
            if ([cfg sentToday:SpTargetKey(t)]) done++;
            else [missing addObject:SpDisplayName(t)];
        }
        if (missing.count) {
            SparksLog(@"🏁 今日任务结束:%lu/%lu(未发出:%@)",
                      (unsigned long)done, (unsigned long)cfg.targets.count,
                      [missing componentsJoinedByString:@"、"]);
        } else {
            SparksLog(@"🏁 今日任务完成:%lu/%lu", (unsigned long)done, (unsigned long)cfg.targets.count);
        }
        [self evalKeepAlive];   // 发完立即收掉保活音频,不留整天空转
        if (self.onStateChange) self.onStateChange();
        return;
    }
    NSDictionary *target = list[idx];
    NSString *key = SpTargetKey(target);
    BOOL isGroup = SpTargetIsGroup(target);
    NSString *name = SpDisplayName(target);   // 显示/AI 称呼:备注优先
    __weak typeof(self) ws = self;
    // sentToday 去重只看第 1 条;目标级 dcount>1 时后续轮继续发
    if (!force && round == 0 && [cfg sentToday:key]) {
        [self sendNextFromIndex:idx + 1 round:0 force:force];
        return;
    }
    NSInteger total = [target[@"dcount"] integerValue];
    if (total < 1) total = 1;
    if (round > 0) SparksLog(@"· 本目标第 %ld/%ld 条", (long)round + 1, (long)total);
    SparksLog(@"── 目标[%lu] %@ (%@·%@)", (unsigned long)idx + 1, name, isGroup ? @"群聊" : @"单聊", key);

    // 目标级覆盖(v2.13 单独设置)
    NSString *tPrompt = [target[@"tprompt"] isKindOfClass:[NSString class]] ? target[@"tprompt"] : nil;
    NSString *tText = [target[@"ttext"] isKindOfClass:[NSString class]] ? target[@"ttext"] : nil;
    BOOL fixedMode = [target[@"mode"] integerValue] == 1 && tText.length > 0;

    void (^body)(NSString *) = ^(NSString *text) {
        typeof(self) s = ws;
        if (!s) return;
        NSString *finalText = text ?: (tText.length ? tText : [cfg nextFallbackForUid:key]);
        if (!text) SparksLog(@"(未出文,兜底:%@)", finalText);

        // 下一推进:同目标还有轮次→短间隔续发;否则→下一目标(常规间隔)
        void (^advance)(void) = ^{
            typeof(self) s2 = ws;
            if (!s2) return;
            SparksConfig *c = s2.config;
            NSUInteger nIdx = (round + 1 < total) ? idx : (idx + 1);
            NSInteger nRound = (round + 1 < total) ? (round + 1) : 0;
            double base = (round + 1 < total) ? 25.0 : c.interval;
            if (force) base = MIN(base, 20.0);   // 手动立即跑:目标间隔收紧,整轮更快
            double delay = base;
            if (base >= 15.0) {
                // 常规间隔:±20s 抖动,最少 15s
                delay = base + (double)(arc4random_uniform(40)) - 20.0;
                if (delay < 15) delay = 15;
            } else if (base > 0) {
                // 亚秒/小间隔:显式要求多快就多快,不加抖动、不抬到 15s
                delay = base;
            } else {
                delay = 15;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                typeof(self) s3 = ws;
                if (!s3) return;
                [s3 sendNextFromIndex:nIdx round:nRound force:force];
            });
        };
        // 文本兜底路径
        void (^sendText)(void) = ^{
            typeof(self) s4 = ws;
            if (!s4) return;
            // 免跳页优先:有该会话的会话模型就直接投递,页面完全不动
            if ([s4 sendTextWithoutPage:finalText target:target]) {
                advance();
                return;
            }
            [s4 openChatAndSendToTarget:target text:finalText completion:^(BOOL ok) {
                if (!ok) [s4 noteTargetFailed:target];   // 记进补发队列,稍后自动再来
                advance();
            }];
        };
        // 随机挑一个媒体文件(目标级:锁定指定图优先,指定图并入随机池)
        SparksConfig *cNow = s.config;
        BOOL tImgOn = [target[@"imgOn"] boolValue];
        NSString *tImgPath = [target[@"imgPath"] isKindOfClass:[NSString class]] ? target[@"imgPath"] : nil;
        BOOL tImgLock = [target[@"imgLock"] boolValue];
        NSString * (^pickMedia)(void) = ^{
            SparksConfig *c = [SparksConfig shared];
            if (tImgLock && tImgPath.length) return tImgPath;
            NSMutableArray *pool = [c.mediaFiles mutableCopy] ?: [NSMutableArray array];
            if (tImgPath.length && ![pool containsObject:tImgPath]) [pool addObject:tImgPath];
            if (!pool.count) return (NSString *)nil;
            return (NSString *)pool[arc4random() % (u_int)pool.count];
        };
        // 语音包:目标级 voice 设了就对它启用 TTS,否则跟全局开关
        NSString *tVoice = [target[@"voice"] isKindOfClass:[NSString class]] ? target[@"voice"] : nil;
        BOOL tts = cNow.audioTpl && (tVoice.length > 0 || cNow.ttsVoiceOn);
        // 图片:目标级 imgOn=开→该目标必发图(图源见上);未设/关→跟全局媒体设置
        BOOL media;
        if (tImgOn) {
            media = cNow.mediaTpl && pickMedia() != nil;
        } else {
            media = cNow.mediaOn && cNow.mediaFiles.count && cNow.mediaTpl;
        }

        if (tts) {
            [SparksTTSHelper synthesize:finalText voice:(tVoice.length ? tVoice : @"zh-CN") completion:^(NSString *path, double dur, NSString *err) {
                typeof(self) s5 = ws;
                if (!s5) return;
                if (path) {
                    [s5 sendMediaFile:path audio:YES duration:dur target:target completion:^(BOOL ok, NSString *e) {
                        if (!ok) {
                            SparksLog(@"⚠️ 语音直发失败(%@),回退文本", e);
                            sendText();
                        } else {
                            [s5.config recordSentText:[NSString stringWithFormat:@"[语音]%@", finalText] forUid:key];
                            advance();
                        }
                    }];
                } else {
                    SparksLog(@"⚠️ TTS 失败(%@),回退文本", err);
                    sendText();
                }
            }];
            return;
        }
        if (media && cNow.mediaInstead) {
            NSString *pick = pickMedia();
            [s sendMediaFile:pick audio:NO duration:0 target:target completion:^(BOOL ok, NSString *e) {
                if (!ok) {
                    SparksLog(@"⚠️ 媒体直发失败(%@),回退文本", e);
                    sendText();
                } else {
                    advance();
                }
            }];
            return;
        }
        // 常规:文本优先;成功后按策略附加一条媒体
        [s openChatAndSendToTarget:target text:finalText completion:^(BOOL ok) {
            if (ok && media) {
                NSString *pick = pickMedia();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    typeof(self) s6 = ws;
                    if (!s6) return;
                    [s6 sendMediaFile:pick audio:NO duration:0 target:target completion:^(BOOL ok2, NSString *e2) {
                        if (!ok2) SparksLog(@"⚠️ 附加媒体失败:%@", e2);
                    }];
                });
            }
            advance();
        }];
    };
    if (fixedMode) {
        SparksLog(@"(独立文案模式,不走 AI)");
        body(tText);
    } else {
        [SparksAI generateForName:name isGroup:isGroup recent:[cfg recentTextsForUid:key] extra:tPrompt
                       completion:body];
    }
}

#pragma mark - 失败补发

// 失败目标入队(按 key 去重):旧版不管 ok,失败了也只是 advance 到下一个目标,
// 一天只有一次机会,赶上 VM/网络抖动就丢一个火花。
- (void)noteTargetFailed:(NSDictionary *)target {
    NSString *key = SpTargetKey(target);
    if (!key.length) return;
    if (!self.retryQueue) self.retryQueue = [NSMutableArray array];
    for (NSDictionary *t in self.retryQueue) {
        if ([SpTargetKey(t) isEqualToString:key]) return;
    }
    [self.retryQueue addObject:target];
    SparksLog(@"⏳ %@ 未发出,已加入补发队列(共 %lu 个)",
              SpDisplayName(target), (unsigned long)self.retryQueue.count);
}

- (void)scheduleRetryPass {
    if (!self.retryQueue.count) return;
    double delay = 120;
    if (self.retryPass == 1) delay = 300;
    else if (self.retryPass >= 2) delay = 600;
    self.retryPass += 1;
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *t in self.retryQueue) [names addObject:SpDisplayName(t)];
    SparksLog(@"🔁 %lu 个目标待补发(%@),%.0f 秒后重试(第 %ld 轮)",
              (unsigned long)self.retryQueue.count,
              [names componentsJoinedByString:@"、"], delay, (long)self.retryPass);
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) s = ws;
        if (s) [s startRetryPass];
    });
}

- (void)startRetryPass {
    if (![SparksLicense isActive]) {
        self.running = NO;
        self.activeTargets = nil;
        SparksLog(@"⚠️ 补发中止:%@", [SparksLicense statusText]);
        return;
    }
    SparksConfig *cfg = self.config;
    NSMutableArray *left = [NSMutableArray array];
    for (NSDictionary *t in self.retryQueue) {
        if (![cfg sentToday:SpTargetKey(t)]) [left addObject:t];   // 已发过的别再发第二遍
    }
    self.retryQueue = left;
    if (!left.count) {
        self.running = NO;
        self.activeTargets = nil;
        SparksLog(@"🏁 补发队列已清空");
        [self evalKeepAlive];
        if (self.onStateChange) self.onStateChange();
        return;
    }
    self.activeTargets = [left copy];
    SparksLog(@"🔁 开始补发:%lu 个目标", (unsigned long)left.count);
    [self sendNextFromIndex:0 round:0 force:NO];
}

#pragma mark - 打开聊天页并发送

- (void)openChatAndSendToTarget:(NSDictionary *)target
                           text:(NSString *)text
                     completion:(void (^)(BOOL ok))done {
    if (![SparksLicense isActive]) { if (done) done(NO); return; }
    NSString *key = SpTargetKey(target);
    if (!key.length) { if (done) done(NO); return; }

    UIApplication *app = UIApplication.sharedApplication;
    if (app.applicationState != UIApplicationStateActive) {
        SparksConfig *cfgNow = self.config;
        if (!(cfgNow.keepAlive && cfgNow.backgroundSend)) {
            SparksLog(@"⚠️ 应用不在前台且未开后台续火花,跳过 %@", SpDisplayName(target));
            if (done) done(NO);
            return;
        }
        SparksLog(@"🌙 后台执行(保活模式):%@", SpDisplayName(target));
    }
    [self.components removeObjectForKey:key];   // 清旧引用,等新页面注册
    self.pollingKey = key;
    self.pollStartAt = [[NSDate date] timeIntervalSince1970];
    self.pageOpenAt = 0;
    self.lastInputVCTryAt = 0;
    self.lastInputVCLogAt = 0;
    self.routeResendCount = 0;
    NSString *urlStr = [NSString stringWithFormat:@"snssdk1128://chat/message?%@=%@",
                        SpTargetIsGroup(target) ? @"cid" : @"uid", key];
    NSURL *url = [NSURL URLWithString:urlStr];
    void (^handler)(BOOL) = ^(BOOL success) {
        if (!success) SparksLog(@"⚠️ 打开聊天页失败:%@", urlStr);
        else SparksLog(@"🚪 路由已受理:%@", urlStr);
    };
    if ([app respondsToSelector:@selector(openURL:options:completionHandler:)]) {
        [app openURL:url options:@{} completionHandler:handler];
    }

    // 轮询等待该 key 的聊天页与组件就绪(方法递归,避免 block 自引用)
    [self pollTarget:target key:key text:text completion:done waited:0];
}

- (void)pollTarget:(NSDictionary *)target key:(NSString *)key
              text:(NSString *)text completion:(void (^)(BOOL))done
            waited:(NSInteger)waited {
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) s = ws;
        if (!s) return;
        if (![SparksLicense isActive]) {
            s.pollingKey = nil;
            if (done) done(NO);
            return;
        }
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (s.pollStartAt <= 0) s.pollStartAt = now;
        Class ctxCls = ClsSendContext();
        id comp = [s.components objectForKey:key];
        BOOL keyOpen = [s.currentChatKey isEqualToString:key];

        // v2.15:页面打开单独打点。等页面和等组件是两件事,旧版共用一个 20s 预算,
        // 页面被系统吞掉 8s 后只剩 12s 给组件注册(+懒创建输入栈),必然超时。
        if (keyOpen && s.pageOpenAt <= 0) {
            s.pageOpenAt = now;
            SparksLog(@"👀 %@ 聊天页已打开(用时 %.1fs),开始等组件",
                      SpDisplayName(target), now - s.pollStartAt);
            [s primeChatInput];   // 页一开立刻拉起输入栈,不再赌 waited==4/24 两个单点
        }

        if (ctxCls && comp && keyOpen) {
            s.pollingKey = nil;   // 就绪,关闭诊断日志窗口
            [s doSendWithComponent:comp contextClass:ctxCls
                              text:text target:target completion:done];
            return;
        }

        if (keyOpen) {
            // 会话已绑但组件未注册:每 ~2s 从 VM 组件中心重试兜底
            if ((waited % 5) == 4) {
                [s registerComponentFromVM:s.currentChatVM];
                comp = [s.components objectForKey:key];
                if (comp && ctxCls) {
                    s.pollingKey = nil;
                    [s doSendWithComponent:comp contextClass:ctxCls
                                      text:text target:target completion:done];
                    return;
                }
            }
            // 40.7 直发终路:页面开了 1.5s 后就动手,之后每 ~2s 重试
            // (旧版只试 waited==14/39 两个点,错过组件懒创建的那几秒就再无机会)
            if (now - s.pageOpenAt >= 1.5 && now - s.lastInputVCTryAt >= 2.0) {
                s.lastInputVCTryAt = now;
                if ([s sendViaInputVC:text target:target]) {
                    s.pollingKey = nil;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        typeof(self) s3 = ws;
                        if (s3) [s3 closeTopChatPage];
                        if (done) done(YES);
                    });
                    return;
                }
            }
        } else {
            // 页面还没开:8s / 18s / 28s 各补发一次路由(旧版只在 8s 补一次,首次被吞就干等到超时)
            NSTimeInterval sinceStart = now - s.pollStartAt;
            if (sinceStart >= 8 && s.routeResendCount < 3
                && sinceStart >= 8 + 10 * (NSTimeInterval)s.routeResendCount) {
                s.routeResendCount += 1;
                SparksLog(@"🔁 %.0fs 页面仍未打开,第 %ld 次重发路由(组件%@ 会话%@)",
                          sinceStart, (long)s.routeResendCount,
                          comp ? @"✓" : @"✗", keyOpen ? @"✓" : @"✗");
                NSURL *url2 = [NSURL URLWithString:
                               [NSString stringWithFormat:@"snssdk1128://chat/message?%@=%@",
                                SpTargetIsGroup(target) ? @"cid" : @"uid", key]];
                [UIApplication.sharedApplication openURL:url2 options:@{} completionHandler:nil];
            }
        }

        // 超时判据:总预算 60s,且页面打开后至少再给 30s —— 两者都到期才算失败
        NSTimeInterval total = now - s.pollStartAt;
        NSTimeInterval afterOpen = s.pageOpenAt > 0 ? (now - s.pageOpenAt) : 0;
        BOOL pageBudgetLeft = s.pageOpenAt > 0 && afterOpen <= 30;
        if (waited + 1 > 200 || (total > 60 && !pageBudgetLeft)) {
            SparksLog(@"❌ %@ 就绪超时:总耗时 %.1fs · 页面%@(打开于 %.1fs) · 发送上下文类%@ · 组件注册%@ · 会话绑定%@ · 当前会话:%@ · 路由重发%ld次",
                      SpDisplayName(target), total,
                      s.pageOpenAt > 0 ? [NSString stringWithFormat:@"开 %.1fs", afterOpen] : @"从未打开",
                      s.pageOpenAt > 0 ? (s.pageOpenAt - s.pollStartAt) : 0.0,
                      ctxCls ? @"✓" : @"✗(抖音已升级?)",
                      comp ? @"✓" : @"✗",
                      keyOpen ? @"✓" : @"✗",
                      s.currentChatKey ?: @"(空)",
                      (long)s.routeResendCount);
            s.pollingKey = nil;
            [s closeTopChatPage];
            if (done) done(NO);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            typeof(self) s2 = ws;
            if (!s2) return;
            [s2 pollTarget:target key:key text:text completion:done waited:waited + 1];
        });
    });
}

// 40.7 直发终路:不找发送组件,直接驱使输入控制器自己的发送链
// VM → listViewController → getInputViewController → textView.setText: → sendTextViewTextMessage:
// (等价于用户把文字敲进输入框后点发送按钮,抖音内部自会走完整管道)
- (BOOL)sendViaInputVC:(NSString *)text target:(NSDictionary *)target {
    if (![SparksLicense isActive]) return NO;
    // 轮询期每 ~2s 会重试本方法,失败原因 10s 内只记一次,否则一屏日志全是同一行
    NSTimeInterval nowTs = [[NSDate date] timeIntervalSince1970];
    BOOL verbose = (self.lastInputVCLogAt <= 0) || (nowTs - self.lastInputVCLogAt > 10);
    if (verbose) self.lastInputVCLogAt = nowTs;
    @try {
        id vm = self.currentChatVM;
        if (![vm respondsToSelector:@selector(listViewController)]) {
            if (verbose) SparksLog(@"⚠️ 直发:VM 无 listViewController");
            return NO;
        }
        id page = [vm performSelector:@selector(listViewController)];
        if (![page respondsToSelector:@selector(getInputViewController)]) {
            if (verbose) SparksLog(@"⚠️ 直发:页面无 getInputViewController");
            return NO;
        }
        id inputVC = [page performSelector:@selector(getInputViewController)];
        if (!inputVC) {
            if (verbose) SparksLog(@"⚠️ 直发:输入控制器为空");
            return NO;
        }
        if (![inputVC respondsToSelector:@selector(textView)]) {
            if (verbose) SparksLog(@"⚠️ 直发:输入控制器无 textView");
            return NO;
        }
        id tv = [inputVC performSelector:@selector(textView)];
        if (!tv || ![tv respondsToSelector:@selector(setText:)]) {
            if (verbose) SparksLog(@"⚠️ 直发:输入框不可用");
            return NO;
        }
        [tv performSelector:@selector(setText:) withObject:text];

        self.inAutoSend = YES;
        if ([inputVC respondsToSelector:@selector(sendTextViewTextMessage:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(inputVC, @selector(sendTextViewTextMessage:), YES);
        } else if ([inputVC respondsToSelector:@selector(sendBtnClicked:)]) {
            [inputVC performSelector:@selector(sendBtnClicked:) withObject:nil];
        } else {
            self.inAutoSend = NO;
            SparksLog(@"⚠️ 直发:输入控制器无发送方法");
            return NO;
        }

        // 与 doSend 相同的收尾:标记/记录/toast/回执探针
        // 标志已在调用发送方法前置位，防同步 hook 回灌模板。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            self.inAutoSend = NO;
        });
        SparksLog(@"📤 直发(输入框链):「%@」", text);
        [self.config markSent:SpTargetKey(target)];
        [self.config recordSentText:text forUid:SpTargetKey(target)];
        [[NSNotificationCenter defaultCenter] postNotificationName:SparksToastNote
                                                            object:nil
                                                          userInfo:@{@"text": [NSString stringWithFormat:@"🔥 已给 %@ 续火花", SpDisplayName(target)]}];
        if (self.onStateChange) self.onStateChange();
        [self scheduleCloseChatIfSilent];
        return YES;
    } @catch (NSException *e) {
        self.inAutoSend = NO;
        SparksLog(@"⚠️ 直发异常:%@", e.name);
        return NO;
    }
}
// 后台静默收尾:发送完成后若 app 不在前台且开了静默模式,把聊天页 pop 掉,
// 用户回到前台不再落在聊天页(BOOL 参数走 objc_msgSend,performSelector withObject 传 @NO 会变 YES)
- (void)scheduleCloseChatIfSilent {
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) s = ws;
        if (!s) return;
        @try {
            if (!s.config.bgSilentSend) return;
            if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) return;
            id vm = s.currentChatVM;
            if (![vm respondsToSelector:@selector(listViewController)]) return;
            id vc = [vm performSelector:@selector(listViewController)];
            if (![vc respondsToSelector:@selector(navigationController)]) return;
            id nav = [vc performSelector:@selector(navigationController)];
            if ([nav respondsToSelector:@selector(popViewControllerAnimated:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(nav, @selector(popViewControllerAnimated:), NO);
                SparksLog(@"🌙 静默收尾:已关闭聊天页");
            }
        } @catch (NSException *e) {
            SparksLog(@"静默收尾异常:%@", e.name);
        }
    });
}

// 首选从会话 VM 拿它的页面控制器(listViewController),再调 getInputViewController;
// 找不到时递归搜子控制器(路由页可能不在导航栈/顶层)
- (void)primeChatInput {
    @try {
        id host = nil;
        if ([self.currentChatVM respondsToSelector:@selector(listViewController)]) {
            host = [self.currentChatVM performSelector:@selector(listViewController)];
        }
        if (host && [host respondsToSelector:@selector(getInputViewController)]) {
            [host performSelector:@selector(getInputViewController)];
            if (self.pollingKey.length) SparksLog(@"👆 已拉起输入栈(VM→页面控制器)");
            return;
        }
        UIViewController *top = [self topViewController];
        UIViewController *found = [self findChatVCFrom:top depth:0];
        if (found) {
            [found performSelector:@selector(getInputViewController)];
            if (self.pollingKey.length) SparksLog(@"👆 已拉起输入栈(视图树搜索)");
            return;
        }
        if (self.pollingKey.length) SparksLog(@"⚠️ 未找到可拉起的聊天输入页(VM 无页控/树内无响应者)");
    } @catch (NSException *e) {
        if (self.pollingKey.length) SparksLog(@"⚠️ 拉起输入栈异常:%@", e.name);
    }
}

// 深搜子控制器找响应 getInputViewController 的页面(含 presented/child/navigation)
- (UIViewController *)findChatVCFrom:(UIViewController *)root depth:(NSInteger)depth {
    if (!root || depth > 6) return nil;
    if ([root respondsToSelector:@selector(getInputViewController)]) return root;
    if (root.presentedViewController) {
        UIViewController *r = [self findChatVCFrom:root.presentedViewController depth:depth + 1];
        if (r) return r;
    }
    for (UIViewController *c in root.childViewControllers) {
        UIViewController *r = [self findChatVCFrom:c depth:depth + 1];
        if (r) return r;
    }
    return nil;
}

- (void)doSendWithComponent:(id)component contextClass:(Class)ctxCls
                       text:(NSString *)text target:(NSDictionary *)target
                 completion:(void (^)(BOOL ok))done {
    if (![SparksLicense isActive]) { if (done) done(NO); return; }
    // 发送前再次确认目标一致,防串门
    if (![self.currentChatKey isEqualToString:SpTargetKey(target)]) {
        SparksLog(@"⚠️ 页面会话与目标不一致,取消发送");
        if (done) done(NO);
        return;
    }
    id ctx = [[ctxCls alloc] init];
    if (!ctx) {
        SparksLog(@"❌ 创建发送上下文失败");
        if (done) done(NO);
        return;
    }
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:text];
    [ctx performSelector:@selector(setContent:) withObject:as];
    SparksConfig *cfg = self.config;
    if (cfg.relayUserInfo) {
        id ui = cfg.sendTemplate[@"userInfo"];
        if ([ui isKindOfClass:[NSDictionary class]] && [ctx respondsToSelector:@selector(setUserInfo:)]) {
            [ctx performSelector:@selector(setUserInfo:) withObject:ui];
        }
    }
    NSString *ef = cfg.sendTemplate[@"enterFrom"];
    if ([ef isKindOfClass:[NSString class]] && ef.length && [ctx respondsToSelector:@selector(setEnterFrom:)]) {
        [ctx performSelector:@selector(setEnterFrom:) withObject:ef];
    }

    self.inAutoSend = YES;
    SparksLog(@"📤 发送给 %@[%@]:「%@」", SpDisplayName(target), SpTargetIsGroup(target) ? @"群" : @"单", text);
    [component performSelector:@selector(sendMessage:) withObject:ctx];
    self.inAutoSend = NO;

    // 回执校验:sendMessage 只是投递,是否真进了会话要靠 hook 到的真实发送确认
    // (此前"成功"toast 在投递后立即弹,管道内被风控/网络拒掉时属于假成功)
    __block BOOL reallySent = NO;
    self.sendAckProbe = ^{
        reallySent = YES;
    };

    [self.config markSent:SpTargetKey(target)];
    [self.config recordSentText:text forUid:SpTargetKey(target)];
    [[NSNotificationCenter defaultCenter] postNotificationName:SparksToastNote
                                                        object:nil
                                                      userInfo:@{@"text": [NSString stringWithFormat:@"🔥 已给 %@ 续火花", SpDisplayName(target)]}];
    if (self.onStateChange) self.onStateChange();
    [self scheduleCloseChatIfSilent];
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) s = ws;
        if (!s) return;
        if (reallySent) {
            SparksLog(@"✅ 发送回执确认:%@", SpDisplayName(target));
        } else {
            SparksLog(@"⚠️ 未捕获发送回执(可能被风控/网络拦截),建议打开聊天页人工确认:%@", SpDisplayName(target));
        }
        s.sendAckProbe = nil;
        [s closeTopChatPage];
        if (done) done(YES);
    });
}

#pragma mark - 免跳页直发

// 40.7.0 实测:文本发送的底层不是组件本身,而是
//   AWEIMSendMessageController -sendMessage:conversation:forwardMessage:mentionUsers:enterFrom:
// (聊天页组件也只是把「上下文 + 会话」转交给它)。所以只要手里有该会话的
// conversation 模型,就能完全不打开聊天页直接投递。
- (BOOL)sendTextWithoutPage:(NSString *)text target:(NSDictionary *)target {
    if (![SparksLicense isActive]) return NO;
    NSString *key = SpTargetKey(target);
    Class ctrlCls = NSClassFromString(@"AWEIMSendMessageController");
    Class ctxCls = ClsSendContext();
    id conv = nil;
    @synchronized (self.conversations) { conv = self.conversations[key]; }
    if (!ctrlCls || !ctxCls || !conv) {
        SparksLog(@"⚠️ 免跳页直发缺件(controller=%@,上下文=%@,会话模型=%@),回退打开聊天页:%@",
                  ctrlCls ? @"有" : @"缺", ctxCls ? @"有" : @"缺",
                  conv ? @"有" : @"缺", SpDisplayName(target));
        return NO;
    }
    id ctx = [[ctxCls alloc] init];
    if (!ctx) return NO;
    SpSetKV(ctx, @"content", [[NSAttributedString alloc] initWithString:text]);
    SparksConfig *cfg = self.config;
    if (cfg.relayUserInfo) {
        id ui = cfg.sendTemplate[@"userInfo"];
        if ([ui isKindOfClass:[NSDictionary class]]) SpSetKV(ctx, @"userInfo", ui);
    }
    NSString *ef = cfg.sendTemplate[@"enterFrom"];
    if (![ef isKindOfClass:[NSString class]] || !ef.length) ef = @"chat";
    SpSetKV(ctx, @"enterFrom", ef);

    __block BOOL acked = NO;
    self.sendAckProbe = ^{ acked = YES; };
    self.inAutoSend = YES;
    id msg = nil;
    @try {
        msg = ((id (*)(id, SEL, id, id, BOOL, id, id))objc_msgSend)(
                  [[ctrlCls alloc] init],
                  @selector(sendMessage:conversation:forwardMessage:mentionUsers:enterFrom:),
                  ctx, conv, NO, (id)nil, ef);
    } @catch (NSException *e) {
        SparksLog(@"⚠️ 免跳页直发异常:%@(%@)", e.name, e.reason);
    }
    self.inAutoSend = NO;
    self.sendAckProbe = nil;
    if (!msg) return NO;

    SparksLog(@"📤 免跳页直发 %@[%@]:「%@」%@", SpDisplayName(target),
              SpTargetIsGroup(target) ? @"群" : @"单", text, acked ? @"(已受理)" : @"");
    [self.config markSent:key];
    [self.config recordSentText:text forUid:key];
    [[NSNotificationCenter defaultCenter] postNotificationName:SparksToastNote object:nil
        userInfo:@{@"text": [NSString stringWithFormat:@"🔥 已给 %@ 续火花", SpDisplayName(target)]}];
    if (self.onStateChange) self.onStateChange();
    return YES;
}

// 底层发送控制器收到发送请求时回调(Tweak.x 的钩子)。
// 旧的组件钩子对免跳页路径不触发,靠这个确认"投递"确实进了发送管道。
- (void)noteControllerSend {
    if (self.sendAckProbe) {
        void (^probe)(void) = self.sendAckProbe;
        probe();
    }
}

- (void)closeTopChatPage {
    UIViewController *top = [self topViewController];
    Class chatCls = NSClassFromString(@"AWEIMMessageListViewController");
    if (!chatCls) return;
    if ([top isKindOfClass:chatCls]) {
        if (top.navigationController && top.navigationController.viewControllers.count > 1) {
            [top.navigationController popViewControllerAnimated:YES];
        } else if (top.presentingViewController) {
            [top dismissViewControllerAnimated:YES completion:nil];
        }
    }
}

- (UIViewController *)topViewController {
    UIViewController *vc = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        vc = ((UINavigationController *)vc).topViewController;
    }
    return vc;
}

@end
