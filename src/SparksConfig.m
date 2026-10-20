//
//  SparksConfig.m
//  配置持久化:NSUserDefaults(应用沙盒内,卸载抖音即清)
//
#import "SparksConfig.h"
#import <UIKit/UIKit.h>

static NSString *const kMaster    = @"sparks.master";
static NSString *const kDailyTime = @"sparks.time";
static NSString *const kInterval  = @"sparks.interval";
static NSString *const kUIStyle   = @"sparks.uistyle";
static NSString *const kNoJump    = @"sparks.nojump";
static NSString *const kAiURL     = @"sparks.ai.url";
static NSString *const kAiKey     = @"sparks.ai.key";
static NSString *const kAiModel   = @"sparks.ai.model";
static NSString *const kAiExtra   = @"sparks.ai.extra";
static NSString *const kFallbacks = @"sparks.fallbacks";
static NSString *const kTargets   = @"sparks.targets";
static NSString *const kRecents   = @"sparks.recents";
static NSString *const kTpl       = @"sparks.tpl";
static NSString *const kRelayUI   = @"sparks.tpl.relayui";
static NSString *const kSentMap   = @"sparks.sent";
static NSString *const kLastRun   = @"sparks.lastrun";
static NSString *const kLastTexts = @"sparks.lasttexts";
static NSString *const kBallSize  = @"sparks.ball.size";
static NSString *const kBallIcon  = @"sparks.ball.icon";
static NSString *const kMaterial  = @"sparks.ui.material";
static NSString *const kAccent    = @"sparks.ui.accent";
static NSString *const kFontAcc   = @"sparks.ui.fontaccent";
static NSString *const kPanelW    = @"sparks.ui.panelw";
static NSString *const kPanelH    = @"sparks.ui.panelh";
static NSString *const kPanelBg   = @"sparks.ui.panelbg";
static NSString *const kPanelBack  = @"sparks.ui.panelbackdrop";
static NSString *const kAnimPre   = @"sparks.ui.animpreset";
static NSString *const kAnimSpd   = @"sparks.ui.animspeed";
static NSString *const kToastOn   = @"sparks.ui.toaston";
static NSString *const kToastY    = @"sparks.ui.toasty";
static NSString *const kCardAlpha = @"sparks.ui.cardalpha";
static NSString *const kTime12    = @"sparks.ui.time12";
static NSString *const kNick      = @"sparks.me.nick";
static NSString *const kExId      = @"sparks.me.exid";
static NSString *const kAuthCode  = @"sparks.me.authcode";
static NSString *const kSign      = @"sparks.me.sign";
static NSString *const kAvatar    = @"sparks.me.avatar";
static NSString *const kDonate    = @"sparks.donate";
static NSString *const kKeepAlive = @"sparks.keepalive";
static NSString *const kMediaFiles = @"sparks.media.files";
static NSString *const kMediaOn    = @"sparks.media.on";
static NSString *const kMediaInstead = @"sparks.media.instead";
static NSString *const kTTSOn      = @"sparks.media.tts";
static NSString *const kMediaTpl   = @"sparks.media.tpl";
static NSString *const kAudioTpl   = @"sparks.media.autpl";
static NSString *const kBgSend    = @"sparks.bgsend";
static NSString *const kBgSilent  = @"sparks.bgsilent";

static NSArray *g_logLines = nil;
static dispatch_queue_t g_logQueue(void) {
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("sparks.log", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

void SparksLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"HH:mm:ss"];
    NSString *line = [NSString stringWithFormat:@"[%@] %@", [df stringFromDate:[NSDate date]], body];
    dispatch_async(g_logQueue(), ^{
        NSMutableArray *arr = g_logLines ? [g_logLines mutableCopy] : [NSMutableArray array];
        [arr addObject:line];
        if (arr.count > 300) [arr removeObjectsInRange:NSMakeRange(0, arr.count - 300)];
        g_logLines = arr;
    });
    NSLog(@"[Sparks] %@", body);
}

NSArray<NSString *> *SparksDefaultFallbacks(void) {
    return @[@"在忙啥呢",
             @"刷到个好玩的,想起你了",
             @"今天过得咋样",
             @"吃了没",
             @"忙不?",
             @"好久没唠了,火花别灭啊",
             @"刚看到个事儿想跟你说",
             @"晚上干嘛呢"];
}

NSString *SparksLogSnapshot(void) {
    __block NSString *snap = @"";
    dispatch_sync(g_logQueue(), ^{
        snap = g_logLines ? [g_logLines componentsJoinedByString:@"\n"] : @"";
    });
    return snap;
}

void SparksClearLogSnapshot(void) {
    dispatch_async(g_logQueue(), ^{
        g_logLines = nil;
    });
}

NSString *SparksVersionString(void) {
    return [NSString stringWithUTF8String:SPARKS_VERSION];
}

NSString *SparksBuildTimeString(void) {
    return [NSString stringWithUTF8String:SPARKS_BUILD_TIME];
}

NSString *const SparksToastNote = @"sparks.toast.note";

#pragma mark - URL 校验

BOOL SparksURLOK(NSURL *url) {
    if (![url.scheme.lowercaseString isEqualToString:@"https"]) return NO;
    NSString *h = url.host.lowercaseString;
    if (h.length == 0) return NO;
    if ([h isEqualToString:@"localhost"] || [h hasSuffix:@".local"] || [h hasSuffix:@".localhost"]) return NO;
    if ([h hasPrefix:@"127."] || [h hasPrefix:@"10."] || [h hasPrefix:@"192.168."] || [h hasPrefix:@"169.254."]) return NO;
    if ([h hasPrefix:@"172."]) {
        NSInteger second = [[h substringFromIndex:4] integerValue];
        if (second >= 16 && second <= 31) return NO;
    }
    if ([h containsString:@"::"] || [h hasPrefix:@"["]) return NO;   // IPv6 私有/环回粗略拦截
    if ([h hasSuffix:@".internal"] || [h hasSuffix:@".lan"]) return NO;
    return YES;
}

@implementation SparksConfig

+ (instancetype)shared {
    static SparksConfig *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[SparksConfig alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self reload];
    }
    return self;
}

- (void)reload {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [self restoreFromMirrorIfNeeded];
    _master    = [d boolForKey:kMaster];
    _dailyTime = [d stringForKey:kDailyTime] ?: @"08:30";
    [self recomputeTodayEffectiveTime];
    double itv = [d doubleForKey:kInterval];
    _interval  = itv > 0 ? itv : 0.1;   // 默认 0.1s(密集续火花);常规值仍可填 15~3600
    _uiStyle   = [d integerForKey:kUIStyle];   // 0 玻璃(默认)/1 控制台/2 目标卡片流/3 极简清单
    // 默认开启:用户要的是"后台自动发",宁可退到语音/图片也不要跳聊天页
    _noJump    = [d objectForKey:kNoJump] ? [d boolForKey:kNoJump] : YES;
    _aiURL   = [d stringForKey:kAiURL] ?: @"https://open.bigmodel.cn/api/paas/v4/chat/completions";
    _aiKey   = [d stringForKey:kAiKey] ?: @"";
    _aiModel = [d stringForKey:kAiModel] ?: @"glm-4-flash";
    _aiExtra = [d stringForKey:kAiExtra] ?: @"";
    NSArray *fb = [d objectForKey:kFallbacks];
    _fallbacks = (fb && [fb isKindOfClass:[NSArray class]] && fb.count) ? fb : SparksDefaultFallbacks();
    NSArray *tg = [d objectForKey:kTargets];
    _targets = tg ? [tg mutableCopy] : [NSMutableArray array];
    // 旧版单聊目标迁移:补 key/type 字段(单聊 key=uid)
    for (NSUInteger i = 0; i < _targets.count; i++) {
        NSDictionary *t = _targets[i];
        if ([t isKindOfClass:[NSDictionary class]] &&
            (![t[@"key"] isKindOfClass:[NSString class]] || !((NSString *)t[@"key"]).length)) {
            NSString *uid = [t[@"uid"] isKindOfClass:[NSString class]] ? t[@"uid"] : nil;
            if (uid.length) {
                NSMutableDictionary *m = [t mutableCopy];
                m[@"key"] = uid;
                if (!m[@"type"]) m[@"type"] = @"single";
                _targets[i] = m;
            }
        }
    }
    NSArray *rc = [d objectForKey:kRecents];
    _recents = rc ? [rc mutableCopy] : [NSMutableArray array];
    NSDictionary *tpl = [d objectForKey:kTpl];
    _sendTemplate = (tpl && [tpl isKindOfClass:[NSDictionary class]]) ? tpl : nil;
    _relayUserInfo = [d boolForKey:kRelayUI];
    NSDictionary *sm = [d objectForKey:kSentMap];
    _sentMap = sm ? [sm mutableCopy] : [NSMutableDictionary dictionary];
    _lastRunDay = [d stringForKey:kLastRun] ?: @"";
    NSDictionary *lt = [d objectForKey:kLastTexts];
    _lastTexts = lt ? [lt mutableCopy] : [NSMutableDictionary dictionary];

    double bs = [d doubleForKey:kBallSize];
    _ballSize = (bs >= 16 && bs <= 80) ? bs : 52;
    _ballIconPath = [d stringForKey:kBallIcon] ?: @"";

    NSInteger mm = [d integerForKey:kMaterial];
    _materialMode = (mm >= 0 && mm <= 2) ? mm : 0;
    _accentHex = [d stringForKey:kAccent] ?: @"";
    _fontFollowsAccent = [d boolForKey:kFontAcc];
    if ([d objectForKey:kFontAcc] == nil) _fontFollowsAccent = YES;   // v2.14 起默认开:标题跟主题色
    double pw = [d doubleForKey:kPanelW];
    double ph = [d doubleForKey:kPanelH];
    CGRect sc = [UIScreen mainScreen].bounds;
    _panelW = (pw >= 280 && pw <= sc.size.width - 16) ? pw : MIN(372, sc.size.width - 20);
    _panelH = (ph >= 420 && ph <= sc.size.height - 80) ? ph : MIN(600, sc.size.height - 110);
    _panelBgPath = [d stringForKey:kPanelBg] ?: @"";
    if ([d objectForKey:kPanelBack] == nil) _panelBackdrop = 0;
    else _panelBackdrop = [d integerForKey:kPanelBack];
    // v2.10.1 液态玻璃:旧默认底衬(1=深色半透明垫层)一次性迁移为"关",
    // 卡片之间不再有背景层;用户显式选过玻璃材质(2)或手动改过的不受影响
    if (_panelBackdrop == 1 && ![d boolForKey:@"sparks.ui.bg2101"]) {
        _panelBackdrop = 0;
        [d setBool:YES forKey:@"sparks.ui.bg2101"];
        [d setInteger:_panelBackdrop forKey:kPanelBack];
    }
    NSInteger ap = [d integerForKey:kAnimPre];
    _animPreset = (ap >= 0 && ap <= 4) ? ap : 0;
    double aspd = [d doubleForKey:kAnimSpd];
    _animSpeed = (aspd >= 0.3 && aspd <= 2.5) ? aspd : 1.0;
    if ([d objectForKey:kToastOn] == nil) _toastOn = YES; else _toastOn = [d boolForKey:kToastOn];
    double ty = [d doubleForKey:kToastY];
    _toastOffsetY = ty > 0 ? ty : 120;
    // 卡片透明度(0.4~1.0,默认 1=最实)
    double ca = [d doubleForKey:kCardAlpha];
    _cardAlpha = (ca >= 0.4 && ca <= 1.0) ? ca : 1.0;
    // 时间显示制式(NO=24小时制默认)
    if ([d objectForKey:kTime12] == nil) _time12h = NO;
    else _time12h = [d boolForKey:kTime12];

    _nickName = [d stringForKey:kNick] ?: @"";
    _exclusiveId = [d stringForKey:kExId] ?: @"";
    _authCode = [d stringForKey:kAuthCode] ?: @"";
    _signature = [d stringForKey:kSign] ?: @"";
    _avatarPath = [d stringForKey:kAvatar] ?: @"";
    _donateURL = [d stringForKey:kDonate] ?: @"https://github.com/liudubin";
    _keepAlive = [d boolForKey:kKeepAlive];
    _backgroundSend = [d boolForKey:kBgSend];
    if ([d objectForKey:kBgSilent] == nil) _bgSilentSend = YES;
    else _bgSilentSend = [d boolForKey:kBgSilent];
    NSArray *mf = [d objectForKey:kMediaFiles];
    _mediaFiles = mf ? [mf mutableCopy] : [NSMutableArray array];
    {
        // 路径失效清理(容器重建后媒体文件可能已丢失)
        NSMutableArray *valid = [NSMutableArray array];
        for (NSString *f in _mediaFiles) {
            if ([f isKindOfClass:[NSString class]] && [[NSFileManager defaultManager] fileExistsAtPath:f]) {
                [valid addObject:f];
            }
        }
        if (valid.count != _mediaFiles.count) {
            SparksLog(@"⚠️ %lu 个媒体文件路径已失效,自动清理(需重新添加)",
                      (unsigned long)(_mediaFiles.count - valid.count));
            _mediaFiles = valid;
        }
    }
    _mediaOn = [d boolForKey:kMediaOn];
    _mediaInstead = [d boolForKey:kMediaInstead];
    _ttsVoiceOn = [d boolForKey:kTTSOn];
    NSDictionary *mt = [d objectForKey:kMediaTpl];
    _mediaTpl = (mt && [mt isKindOfClass:[NSDictionary class]]) ? mt : nil;
    NSDictionary *at = [d objectForKey:kAudioTpl];
    _audioTpl = (at && [at isKindOfClass:[NSDictionary class]]) ? at : nil;
}

#pragma mark 越狱全局镜像(覆盖更新/换容器装抖音不清配置)

// 镜像路径:roothide/dopamine 的 /var/jb 优先,回退裸 /var/mobile;沙盒拦截时整体降级
static NSString *SpMirrorPath(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *cands = @[
            @"/var/jb/var/mobile/Library/Preferences/com.zhipu.sparkshelper.json",
            @"/var/mobile/Library/Preferences/com.zhipu.sparkshelper.json",
        ];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *p in cands) {
            if ([fm fileExistsAtPath:p]) {   // 已存在直接命中,零写盘
                cached = p;
                break;
            }
            NSString *dir = [p stringByDeletingLastPathComponent];
            if (![fm fileExistsAtPath:dir]) {
                [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            }
            if ([@"{}" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
                cached = p;
                break;
            }
        }
        if (cached) {
            NSLog(@"[Sparks] config mirror at %@", cached);
        } else {
            NSLog(@"[Sparks] config mirror unavailable (sandboxed?)");
        }
    });
    return cached;
}

// 沙盒域是否有本插件配置
static BOOL SpSandboxHasConfig(NSUserDefaults *d) {
    // O(1) 单键探测(启动路径优化):sparks.time 每次 save 必写;
    // 旧版 dictionaryRepresentation 会全量物化含抖音自身的全部键,拖慢 dylib 加载
    return [d objectForKey:@"sparks.time"] != nil;
}

- (void)writeMirror {
    NSString *path = SpMirrorPath();
    if (!path) return;
    NSString *json = [self exportBackupJSON];
    if (json.length) {
        [json writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

- (BOOL)restoreFromMirrorIfNeeded {
    if (SpSandboxHasConfig([NSUserDefaults standardUserDefaults])) return NO;
    NSString *path = SpMirrorPath();
    if (!path) return NO;
    NSString *json = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (json.length && [self importBackupJSON:json]) {
        SparksLog(@"♻️ 已从越狱全局镜像恢复配置(容器曾被重建)");
        return YES;
    }
    return NO;
}

- (void)save {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:_master forKey:kMaster];
    [d setObject:_dailyTime forKey:kDailyTime];
    [self recomputeTodayEffectiveTime];
    [d setDouble:_interval forKey:kInterval];
    [d setObject:_aiURL forKey:kAiURL];
    [d setObject:_aiKey forKey:kAiKey];
    [d setObject:_aiModel forKey:kAiModel];
    [d setObject:_aiExtra forKey:kAiExtra];
    [d setObject:_fallbacks forKey:kFallbacks];
    [d setObject:_targets forKey:kTargets];
    [d setObject:_recents forKey:kRecents];
    if (_sendTemplate) [d setObject:_sendTemplate forKey:kTpl]; else [d removeObjectForKey:kTpl];
    [d setBool:_relayUserInfo forKey:kRelayUI];
    [d setObject:_sentMap forKey:kSentMap];
    [d setObject:_lastRunDay forKey:kLastRun];
    [d setObject:_lastTexts forKey:kLastTexts];
    [d setDouble:_ballSize forKey:kBallSize];
    if (_ballIconPath.length) [d setObject:_ballIconPath forKey:kBallIcon]; else [d removeObjectForKey:kBallIcon];
    [d setInteger:_materialMode forKey:kMaterial];
    [d setInteger:_uiStyle forKey:kUIStyle];
    [d setBool:_noJump forKey:kNoJump];
    [d setObject:_accentHex forKey:kAccent];
    [d setBool:_fontFollowsAccent forKey:kFontAcc];
    [d setDouble:_panelW forKey:kPanelW];
    [d setDouble:_panelH forKey:kPanelH];
    if (_panelBgPath.length) [d setObject:_panelBgPath forKey:kPanelBg]; else [d removeObjectForKey:kPanelBg];
    [d setInteger:_panelBackdrop forKey:kPanelBack];
    [d setInteger:_animPreset forKey:kAnimPre];
    [d setDouble:_animSpeed forKey:kAnimSpd];
    [d setBool:_toastOn forKey:kToastOn];
    [d setDouble:_toastOffsetY forKey:kToastY];
    [d setDouble:_cardAlpha forKey:kCardAlpha];
    [d setBool:_time12h forKey:kTime12];
    [d setObject:_nickName forKey:kNick];
    [d setObject:_exclusiveId forKey:kExId];
    if (_authCode.length) [d setObject:_authCode forKey:kAuthCode]; else [d removeObjectForKey:kAuthCode];
    [d setObject:_signature forKey:kSign];
    if (_avatarPath.length) [d setObject:_avatarPath forKey:kAvatar]; else [d removeObjectForKey:kAvatar];
    [d setObject:_donateURL forKey:kDonate];
    [d setBool:_keepAlive forKey:kKeepAlive];
    [d setBool:_backgroundSend forKey:kBgSend];
    [d setBool:_bgSilentSend forKey:kBgSilent];
    [d setObject:_mediaFiles forKey:kMediaFiles];
    [d setBool:_mediaOn forKey:kMediaOn];
    [d setBool:_mediaInstead forKey:kMediaInstead];
    [d setBool:_ttsVoiceOn forKey:kTTSOn];
    if (_mediaTpl) [d setObject:_mediaTpl forKey:kMediaTpl]; else [d removeObjectForKey:kMediaTpl];
    if (_audioTpl) [d setObject:_audioTpl forKey:kAudioTpl]; else [d removeObjectForKey:kAudioTpl];
    [d synchronize];
    [self writeMirror];
}

- (void)saveSoon {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(save) object:nil];
    [self performSelector:@selector(save) withObject:nil afterDelay:0.5];
}

#pragma mark 发送时间解析(单点/时间段)

// 解析 HH:mm 中的分钟数,失败返回 -1
static NSInteger SpParseHM(NSString *s) {
    NSArray *hm = [s componentsSeparatedByString:@":"];
    if (hm.count != 2) return -1;
    NSInteger h = [hm[0] integerValue], m = [hm[1] integerValue];
    if (h < 0 || h > 23 || m < 0 || m > 59) return -1;
    return h * 60 + m;
}

// 今日实际发送时刻:单点=原值;时间段(a-b)=按"日期字符串"确定性抽样,
// 同一天内多次 reload/save 抽到同一时刻,每天换一天自然变化(拟人且不跳动)
- (void)recomputeTodayEffectiveTime {
    NSString *t = _dailyTime ?: @"08:30";
    NSRange dash = [t rangeOfString:@"-"];
    if (dash.location == NSNotFound) {
        _todayEffectiveTime = t;
        return;
    }
    NSInteger a = SpParseHM([t substringToIndex:dash.location]);
    NSInteger b = SpParseHM([t substringFromIndex:NSMaxRange(dash)]);
    if (a < 0 || b < 0) {
        _todayEffectiveTime = t;   // 格式非法原样返回,引擎侧兜底
        return;
    }
    if (b < a) { NSInteger tmp = a; a = b; b = tmp; }
    if (b == a) {
        _todayEffectiveTime = [NSString stringWithFormat:@"%02ld:%02ld", (long)a / 60, (long)a % 60];
        return;
    }
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyyMMdd";
    NSUInteger seed = (NSUInteger)[[df stringFromDate:[NSDate date]] integerValue];
    seed = seed ^ (NSUInteger)_dailyTime.hash;
    // 简易 LCG 抖动,避免每分钟心跳重掷
    seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
    NSInteger span = b - a;
    NSInteger pick = a + (NSInteger)(seed % (NSUInteger)(span + 1));
    _todayEffectiveTime = [NSString stringWithFormat:@"%02ld:%02ld", (long)pick / 60, (long)pick % 60];
}

#pragma mark 发送记录

- (NSString *)todayString {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"yyyy-MM-dd"];
    return [df stringFromDate:[NSDate date]];
}

- (BOOL)sentToday:(NSString *)uid {
    NSString *v = _sentMap[uid];
    return [v isEqualToString:[self todayString]];
}

- (void)markSent:(NSString *)uid {
    if (!uid.length) return;
    _sentMap[uid] = [self todayString];
    [self saveSoon];
}

- (void)recordSentText:(NSString *)text forUid:(NSString *)uid {
    if (!uid.length || !text.length) return;
    NSMutableArray *arr = [_lastTexts[uid] mutableCopy] ?: [NSMutableArray array];
    [arr addObject:text];
    if (arr.count > 6) [arr removeObjectsInRange:NSMakeRange(0, arr.count - 6)];
    _lastTexts[uid] = arr;
    [self saveSoon];
}

- (NSArray<NSString *> *)recentTextsForUid:(NSString *)uid {
    return _lastTexts[uid] ?: @[];
}

- (void)updateTarget:(NSString *)key set:(void (^)(NSMutableDictionary *target))mut {
    if (!key.length || !mut) return;
    for (NSUInteger i = 0; i < self.targets.count; i++) {
        NSDictionary *t = self.targets[i];
        NSString *k = [t[@"key"] isKindOfClass:[NSString class]] ? t[@"key"] : t[@"uid"];
        if (![k isKindOfClass:[NSString class]] || ![k isEqualToString:key]) continue;
        NSMutableDictionary *m = [t mutableCopy];
        mut(m);
        self.targets[i] = m;
        [self saveSoon];
        return;
    }
}

- (NSString *)nextFallbackForUid:(NSString *)uid {
    if (!self.fallbacks.count) return @"和你聊天的每一天都很开心,火花继续烧~";   // 防取模零崩溃
    NSUInteger hash = uid.longLongValue ^ (NSUInteger)[[NSDate date] timeIntervalSince1970] / 86400;
    return self.fallbacks[hash % self.fallbacks.count];
}

- (UIColor *)accentColor {
    if (_accentHex.length >= 6) {
        NSString *h = [_accentHex lowercaseString];
        if ([h hasPrefix:@"#"]) h = [h substringFromIndex:1];
        unsigned rgb = 0;
        [[NSScanner scannerWithString:h] scanHexInt:&rgb];
        return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                               green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0 alpha:1];
    }
    return [UIColor colorWithRed:1.0 green:0.694 blue:0.239 alpha:1.0];   // 默认琥珀 #FFB13D(液态玻璃主题)
}

#pragma mark 备份/恢复

- (NSString *)exportBackupJSON {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    for (NSString *k in all) {
        if ([k hasPrefix:@"sparks."]) {
            out[k] = all[k];
        }
    }
    out[@"sparks._backupTime"] = [self todayString];
    NSData *data = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

- (BOOL)importBackupJSON:(NSString *)json {
    if (!json.length) return NO;
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return NO;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return NO;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSInteger n = 0;
    for (NSString *k in obj) {
        if ([k isKindOfClass:[NSString class]] && [k hasPrefix:@"sparks."] && ![k containsString:@"_backupTime"]) {
            [d setObject:obj[k] forKey:k];
            n++;
        }
    }
    [d synchronize];
    [self reload];
    if (n > 0) [self writeMirror];   // 恢复后立即回写镜像,避免后续无 save 时镜像滞后
    return n > 0;
}

@end
