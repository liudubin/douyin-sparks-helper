//
//  SparksPanel.m
//  悬浮球 + 液态玻璃卡片面板 v2.0.0
//
//  材质:0 液态玻璃(UIGlassEffect,深色染底) 1 玻璃 2 磨砂 —— 设置-外观可切换
//  iOS 26+ 玻璃经 NSClassFromString 运行时弱调用(16.5 SDK 可编译,无链接符号)
//
#import "SparksPanel.h"
#import "SparksEngine.h"
#import "SparksAI.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <PhotosUI/PhotosUI.h>
#import <Photos/Photos.h>
#import <dlfcn.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>

extern NSString *SparksLogSnapshot(void);
extern void SparksClearLogSnapshot(void);

#pragma mark - 目标 key/类型(单聊=uid,群聊=cid;旧目标无 key 回退 uid)

static NSString *SpTargetKeyOf(NSDictionary *t) {
    NSString *k = t[@"key"];
    if (![k isKindOfClass:[NSString class]] || !k.length) k = t[@"uid"];
    return k ?: @"";
}

static BOOL SpTargetIsGroupOf(NSDictionary *t) {
    return [t[@"type"] isEqualToString:@"group"];
}

// 目标显示名:备注(v2.13 单独设置)>原始昵称>key,列表/详情/日志统一
static NSString *SpTargetDisplayName(NSDictionary *t) {
    NSString *r = [t[@"remark"] isKindOfClass:[NSString class]] ? t[@"remark"] : nil;
    if (r.length) return r;
    NSString *n = [t[@"name"] isKindOfClass:[NSString class]] ? t[@"name"] : nil;
    if (n.length) return n;
    return SpTargetKeyOf(t);
}

#pragma mark - 辅助

static BOOL SpGlassAvailable(void) {
    static BOOL avail;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        avail = (NSClassFromString(@"UIGlassEffect") != nil);
    });
    return avail;
}

// 玻璃染色(仅 iOS 26+ 生效,KVC 弱调用,失败静默)
static void SpGlassSetTint(UIVisualEffectView *glassView, UIColor *tint) {
    if (!SpGlassAvailable() || !glassView.effect) return;
    @try {
        if ([glassView.effect respondsToSelector:NSSelectorFromString(@"setTintColor:")]) {
            [glassView.effect setValue:tint forKey:@"tintColor"];
        }
    } @catch (NSException *e) {
    }
}

// 深色染底:原生玻璃默认极透,亮背景下文字不可读
// v2.4.5 加深:0.46 遮不住亮视频/白页,0.66 起白字对比度才稳
// 染底色由调用处按卡片透明度系数现场构造(v2.14 起 SpMakeGlassView 内联)

// 原生玻璃视图:材质模式 0液态玻璃(iOS26+,深色染底) 1玻璃(清透) 2磨砂(浓雾染底);旧系统回退原生深色材质
static UIVisualEffectView *SpMakeGlassView(void) {
    SparksConfig *cfg = [SparksConfig shared];
    NSInteger mode = cfg.materialMode;
    double ca = (cfg.cardAlpha >= 0.4 && cfg.cardAlpha <= 1.0) ? cfg.cardAlpha : 1.0;
    if (mode == 0 && SpGlassAvailable()) {
        id effect = [[NSClassFromString(@"UIGlassEffect") alloc] init];
        UIVisualEffectView *v = [[UIVisualEffectView alloc] initWithEffect:(UIVisualEffect *)effect];
        // 染底浓度随卡片透明度系数缩放(越小越透)
        SpGlassSetTint(v, [UIColor colorWithWhite:0.02 alpha:0.66 * ca]);
        return v;
    }
    UIBlurEffectStyle style = (mode == 2) ? UIBlurEffectStyleSystemMaterialDark
                                          : UIBlurEffectStyleSystemUltraThinMaterialDark;
    UIVisualEffectView *v = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:style]];
    if (mode == 2) {
        // 两种 Material blur 样式在 iOS26 视觉几乎相同——磨砂加染底拉开差距;0.24 不至于发黑
        v.contentView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.24 * ca];
    }
    return v;
}

static UIColor *SpW(CGFloat alpha) {
    return [UIColor colorWithWhite:1 alpha:alpha];
}

// 磨砂等系统材质的渲染不跟随 UIVisualEffectView 自身圆角(iOS26 实测),
// 统一套一层普通裁切容器承担圆角,玻璃本体不再设角
static UIView *SpGlassWrap(UIVisualEffectView *glass, CGFloat radius) {
    UIView *clip = [[UIView alloc] init];
    clip.translatesAutoresizingMaskIntoConstraints = NO;
    clip.layer.cornerRadius = radius;
    clip.layer.cornerCurve = kCACornerCurveContinuous;
    clip.clipsToBounds = YES;
    glass.translatesAutoresizingMaskIntoConstraints = NO;
    [clip addSubview:glass];
    [NSLayoutConstraint activateConstraints:@[
        [glass.topAnchor constraintEqualToAnchor:clip.topAnchor],
        [glass.bottomAnchor constraintEqualToAnchor:clip.bottomAnchor],
        [glass.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
        [glass.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
    ]];
    return clip;
}

// 主题色(配置 hex,默认火焰橙)
static UIColor *SpAccent(void) {
    return [SparksConfig shared].accentColor;
}

static UIFont *SpRounded(CGFloat size, CGFloat weight) {
    UIFontDescriptor *desc = [[UIFontDescriptor alloc] initWithFontAttributes:@{
        UIFontDescriptorFamilyAttribute: @"System",
        UIFontDescriptorTraitsAttribute: @{UIFontWeightTrait: @(weight)},
    }];
    UIFontDescriptor *rounded = [desc fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    return [UIFont fontWithDescriptor:rounded size:size];
}

static NSInteger gEditingFields = 0;   // 有输入框聚焦时不重建内容

static UIColor *SpTitleColor(void) {
    SparksConfig *cfg = [SparksConfig shared];
    return cfg.fontFollowsAccent ? SpAccent() : SpW(0.92);
}

static UILabel *SpMakeTitleLabel(NSString *text, CGFloat size) {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:UIFontWeightMedium];
    l.textColor = SpTitleColor();
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

// HH:mm -> 按制式显示:24小时制原样;12小时制带 上午/中午/下午/晚上
static NSString *SpFormatHM(NSString *hhmm) {
    if (!hhmm.length) return hhmm;
    NSArray *pp = [hhmm componentsSeparatedByString:@":"];
    if (pp.count < 2) return hhmm;
    NSInteger h = [pp[0] integerValue];
    NSInteger m = [pp[1] integerValue];
    if (m < 0 || m > 59) m = 0;
    if (![SparksConfig shared].time12h) {
        return [NSString stringWithFormat:@"%02ld:%02ld", (long)h, (long)m];
    }
    NSString *tag = (h < 11) ? @"上午" : ((h < 13) ? @"中午" : ((h < 18) ? @"下午" : @"晚上"));
    NSInteger h12 = h % 12;
    if (h12 == 0) h12 = 12;
    return [NSString stringWithFormat:@"%@ %ld:%02ld", tag, (long)h12, (long)m];
}

static UILabel *SpMakeSubLabel(NSString *text) {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:11];
    l.textColor = SpW(0.72);
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

// 带状态圆点前缀的标题
static NSAttributedString *SpDotTitle(NSString *name, UIColor *dotColor) {
    NSString *plain = [NSString stringWithFormat:@"●  %@", name ?: @""];
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc]
        initWithString:plain
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightMedium],
                         NSForegroundColorAttributeName: SpW(0.97)}];
    [as addAttribute:NSForegroundColorAttributeName value:dotColor range:NSMakeRange(0, 1)];
    return as;
}

// 行间分隔线(iOS 设置风格:浅色)
static UIView *SpRowSeparator(void) {
    UIView *v = [[UIView alloc] init];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    [v.heightAnchor constraintEqualToConstant:0.5].active = YES;
    return v;
}

// AI 服务商预设
static NSArray<NSDictionary *> *SpAIPresets(void) {
    return @[
        @{@"name": @"智谱 GLM",   @"url": @"https://open.bigmodel.cn/api/paas/v4/chat/completions",  @"model": @"glm-4-flash"},
        @{@"name": @"OpenAI",     @"url": @"https://api.openai.com/v1/chat/completions",              @"model": @"gpt-4o-mini"},
        @{@"name": @"DeepSeek",   @"url": @"https://api.deepseek.com/chat/completions",               @"model": @"deepseek-v4-flash"},
        @{@"name": @"Kimi",       @"url": @"https://api.moonshot.cn/v1/chat/completions",             @"model": @"moonshot-v1-8k"},
        @{@"name": @"通义千问",    @"url": @"https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", @"model": @"qwen-turbo"},
    ];
}

// 更新下载域名白名单
static NSArray<NSString *> *SpUpdateHosts(void) {
    return @[@"api.github.com", @"github.com", @"objects.githubusercontent.com", @"release-assets.githubusercontent.com"];
}

static NSArray *SpAnimPresetNames(void) {
    return @[@"弹簧", @"缩放", @"上浮", @"侧滑", @"淡入"];
}

static NSArray *SpMaterialNames(void) {
    return @[@"液态玻璃", @"玻璃", @"磨砂"];
}

static NSArray<NSString *> *SpAccentPresets(void) {
    return @[@"FF7A2E", @"FF375F", @"30D158", @"0A84FF", @"BF5AF2", @"FFD60A", @"64D2FF", @"FFFFFF"];
}

#pragma mark - GIF 图标视图
// 发热优化:不用 CADisplayLink(120Hz 机型每秒空转 120 次唤醒),
// 改为按下一帧时长自链的 weak-dispatch 定时:唤醒频率 = GIF 帧率(封顶 15fps),
// 随视图释放自动停止;解码用缩略图(最长边 160px)降内存与解码开销;退后台自动暂停。

@interface SparksGifIconView : UIView
- (nullable instancetype)initWithFilePath:(NSString *)path;
- (void)setPlaying:(BOOL)playing;
@end

@implementation SparksGifIconView {
    UIImageView *_iv;
    NSArray<UIImage *> *_frames;
    NSArray<NSNumber *> *_durations;
    NSUInteger _idx;
    BOOL _wantPlay;
    BOOL _appActive;
}

- (instancetype)initWithFilePath:(NSString *)path {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _appActive = YES;
        NSURL *url = [NSURL fileURLWithPath:path];
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        if (!src) return self;
        size_t count = CGImageSourceGetCount(src);
        NSUInteger cap = count > 200 ? 200 : count;   // 帧数保险丝
        NSMutableArray *frames = [NSMutableArray array];
        NSMutableArray *durs = [NSMutableArray array];
        NSDictionary *thumbOpts = @{
            (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(160),
            (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        };
        for (NSUInteger i = 0; i < cap; i++) {
            CGImageRef img = CGImageSourceCreateThumbnailAtIndex(src, i, (__bridge CFDictionaryRef)thumbOpts);
            if (!img) continue;
            [frames addObject:[UIImage imageWithCGImage:img]];
            CFRelease(img);
            NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, i, NULL));
            NSDictionary *gifDict = props[(NSString *)kCGImagePropertyGIFDictionary];
            double d = [gifDict[(NSString *)kCGImagePropertyGIFDelayTime] doubleValue];
            if (d < 0.02) d = 0.1;
            if (d < 1.0 / 12.0) d = 1.0 / 12.0;   // 帧率封顶 12fps(发热四轮:小图标 12fps 视觉足够,唤醒再降)
            [durs addObject:@(d)];
        }
        CFRelease(src);
        if (frames.count < 2 || durs.count != frames.count) {
            _frames = frames.count ? @[frames[0]] : nil;
            _durations = nil;
        } else {
            _frames = frames;
            _durations = durs;
        }

        _iv = [[UIImageView alloc] initWithFrame:CGRectZero];
        _iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _iv.contentMode = UIViewContentModeScaleAspectFill;   // 居中裁切,非正方形 GIF 不拉伸变形
        _iv.clipsToBounds = YES;
        [self addSubview:_iv];
        _iv.image = _frames.firstObject;

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        __weak typeof(self) ws = self;
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil
                     usingBlock:^(NSNotification *n) {
            typeof(self) s = ws;
            if (s) s->_appActive = NO;   // 链式回调见到即停,回前台按需重续
        }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil
                     usingBlock:^(NSNotification *n) {
            typeof(self) s = ws;
            if (!s) return;
            s->_appActive = YES;
            if (s->_wantPlay) [s scheduleNextFrame];
        }];
    }
    return self;
}

- (void)scheduleNextFrame {
    if (!_durations.count || !_appActive || !_wantPlay) return;
    double d = _durations[_idx].doubleValue;
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) s = ws;
        if (!s || !s->_appActive || !s->_wantPlay) return;
        s->_idx = (s->_idx + 1) % s->_frames.count;
        s->_iv.image = s->_frames[s->_idx];
        [s scheduleNextFrame];
    });
}

- (void)setPlaying:(BOOL)playing {
    _wantPlay = playing;
    if (playing) {
        [self scheduleNextFrame];
    }
}

- (void)willMoveToSuperview:(UIView *)newSuperview {
    [super willMoveToSuperview:newSuperview];
    if (!newSuperview) {
        _wantPlay = NO;   // 视图移除即停链(weak 引用,无持有)
    }
}
@end

#pragma mark - 玻璃卡片

#pragma mark - 界面风格(v2.19.0:同一套面板,四种皮)

// v2.22.0:只保留「控制台」一套布局,其余三套皮肤与风格开关已删除
static CGFloat SpCardRadius(void) { return 20; }
static UIColor *SpCardFill(void)  { return [UIColor colorWithWhite:0.09 alpha:0.94]; }
static UIColor *SpCardStroke(void){ return [UIColor colorWithWhite:1 alpha:0.12]; }
static UIColor *SpArtTitleColor(void) { return SpW(0.55); }
static UIColor *SpArtTextColor(void)  { return [UIColor whiteColor]; }

#pragma mark - 环形进度(控制台风格首屏)

@interface SparksRingGauge : UIView
- (void)setDone:(NSUInteger)done total:(NSUInteger)total;
- (void)setDone:(NSUInteger)done total:(NSUInteger)total animated:(BOOL)animated;
@end

@implementation SparksRingGauge {
    CAShapeLayer *_track, *_bar;
    UILabel *_num, *_cap;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _track = [CAShapeLayer layer];
        _bar = [CAShapeLayer layer];
        for (CAShapeLayer *l in @[_track, _bar]) {
            l.fillColor = UIColor.clearColor.CGColor;
            l.lineWidth = 8;
            l.lineCap = kCALineCapRound;
            [self.layer addSublayer:l];
        }
        _track.strokeColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
        _bar.strokeColor = SpAccent().CGColor;
        _bar.strokeEnd = 0;

        _num = [[UILabel alloc] init];
        _num.font = SpRounded(22, 0.8);
        _num.textColor = [UIColor whiteColor];
        _num.textAlignment = NSTextAlignmentCenter;

        _cap = [[UILabel alloc] init];
        _cap.text = @"今日已发";
        _cap.font = [UIFont systemFontOfSize:10];
        _cap.textColor = SpW(0.55);
        _cap.textAlignment = NSTextAlignmentCenter;

        [self addSubview:_num];
        [self addSubview:_cap];
    }
    return self;
}

- (void)setDone:(NSUInteger)done total:(NSUInteger)total {
    [self setDone:done total:total animated:YES];
}

// 动效:圆环从当前值扫到新值,中间数字跟着滚
- (void)setDone:(NSUInteger)done total:(NSUInteger)total animated:(BOOL)animated {
    CGFloat p = total ? (CGFloat)done / (CGFloat)total : 0;
    _bar.strokeColor = (total && done >= total) ? [UIColor systemGreenColor].CGColor : SpAccent().CGColor;
    NSString *final = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)done, (unsigned long)total];

    if (!animated || !self.window) {
        _num.text = final;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _bar.strokeEnd = p;
        [CATransaction commit];
        return;
    }

    CGFloat from = _bar.presentationLayer ? [[_bar presentationLayer] strokeEnd] : _bar.strokeEnd;
    CABasicAnimation *sweep = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    sweep.fromValue = @(from);
    sweep.toValue = @(p);
    sweep.duration = 0.9;
    sweep.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    _bar.strokeEnd = p;
    [_bar addAnimation:sweep forKey:@"spSweep"];

    // 数字滚动:12 步 0.9s 走完
    NSInteger steps = 12;
    for (NSInteger i = 1; i <= steps; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * i / steps * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSUInteger d = (NSUInteger)((double)done * (double)i / (double)steps);
            if (i == steps) d = done;
            self->_num.text = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)d, (unsigned long)total];
        });
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat r = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) / 2 - 5;
    CGPoint c = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:c radius:r
                                                        startAngle:-M_PI_2
                                                          endAngle:-M_PI_2 + 2 * M_PI
                                                         clockwise:YES];
    _track.path = path.CGPath;
    _bar.path = path.CGPath;
    _num.frame = CGRectMake(0, c.y - 18, CGRectGetWidth(self.bounds), 24);
    _cap.frame = CGRectMake(0, c.y + 6, CGRectGetWidth(self.bounds), 14);
}

@end

@interface SparksGlassCard : UIView
- (instancetype)initWithCardTitle:(NSString *)title;
- (void)addRow:(UIView *)row;
@property (nonatomic, readonly) UIView *surface;
@end

@implementation SparksGlassCard {
    UIView *_plate;               // 实底容器(圆角/描边)
    UIView *_body;                // 内容容器(等于 _plate)
    UIStackView *_stack;
}

- (instancetype)initWithCardTitle:(NSString *)title {
    self = [super initWithFrame:CGRectMake(0, 0, 320, 40)];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.layer.cornerRadius = SpCardRadius();
        self.layer.cornerCurve = kCACornerCurveContinuous;
        // v2.14.2:卡片不加投影(用户报"边缘方形阴影";玻璃卡直浮视频更干净,也省 GPU)

        {
            UIView *flat = [[UIView alloc] init];
            flat.translatesAutoresizingMaskIntoConstraints = NO;
            flat.backgroundColor = SpCardFill();
            flat.layer.cornerRadius = SpCardRadius();
            flat.layer.cornerCurve = kCACornerCurveContinuous;
            flat.layer.borderWidth = 1;
            flat.layer.borderColor = SpCardStroke().CGColor;
            [self addSubview:flat];
            _plate = flat;
            _body = flat;
            CGFloat plateTop = title.length ? 26 : 0;   // 标题在卡外,顶部让出段头高度
            [NSLayoutConstraint activateConstraints:@[
                [flat.topAnchor constraintEqualToAnchor:self.topAnchor constant:plateTop],
                [flat.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
                [flat.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
                [flat.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            ]];
        }

        if (title.length) {
            // 标题搬到卡外做段头
            UILabel *sec = [[UILabel alloc] init];
            sec.text = title;
            sec.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
            sec.textColor = SpArtTitleColor();
            sec.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:sec];
            [NSLayoutConstraint activateConstraints:@[
                [sec.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
                [sec.topAnchor constraintEqualToAnchor:self.topAnchor],
                [sec.heightAnchor constraintEqualToConstant:20],
            ]];
        } else if (title.length) {
            [self ensureStack];
            // 标题缩进容器:与行首图标方块(16pt)对齐留呼吸感,不影响行堆叠
            UIView *titleWrap = [[UIView alloc] init];
            titleWrap.translatesAutoresizingMaskIntoConstraints = NO;
            titleWrap.userInteractionEnabled = NO;
            UILabel *titleLabel = [[UILabel alloc] init];
            titleLabel.text = title;
            CGFloat titleSz = 13;
            titleLabel.font = [UIFont systemFontOfSize:titleSz weight:UIFontWeightSemibold];
            titleLabel.textColor = SpArtTitleColor();
            titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
            [titleWrap addSubview:titleLabel];
            [titleLabel.leadingAnchor constraintEqualToAnchor:titleWrap.leadingAnchor constant:18].active = YES;
            [titleLabel.centerYAnchor constraintEqualToAnchor:titleWrap.centerYAnchor].active = YES;
            [_stack addArrangedSubview:titleWrap];
            [titleWrap.heightAnchor constraintEqualToConstant:22].active = YES;
            [_stack setCustomSpacing:6 afterView:titleWrap];
        }
    }
    return self;
}

// 行堆叠按需创建:直接铺内容的卡(进度/操作/头部)不建堆叠
- (void)ensureStack {
    if (_stack) return;
    _stack = [[UIStackView alloc] init];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 0;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_body addSubview:_stack];
    [NSLayoutConstraint activateConstraints:@[
        [_stack.topAnchor constraintEqualToAnchor:_body.topAnchor constant:6],
        [_stack.bottomAnchor constraintEqualToAnchor:_body.bottomAnchor constant:-6],
        // v2.14:行内容离卡片边框留 14pt(与卡片边距一致),不再贴边
        [_stack.leadingAnchor constraintEqualToAnchor:_body.leadingAnchor constant:14],
        [_stack.trailingAnchor constraintEqualToAnchor:_body.trailingAnchor constant:-14],
    ]];
}

- (UIView *)surface {
    return _body;
}

- (void)addRow:(UIView *)row {
    [self ensureStack];
    [_stack addArrangedSubview:row];
}

@end

#pragma mark - 胶囊按钮(玻璃底)

@interface SparksCapsuleButton : UIControl
- (instancetype)initWithTitle:(NSString *)title icon:(NSString *)sysImageName primary:(BOOL)primary;
@property (nonatomic, copy) void (^onTap)(void);
/// 容器注入:满宽约束(常态)与 48×48 方约束(收缩态),切换 active 实现收纳
@property (nonatomic, strong) NSLayoutConstraint *stretchWidth;
@property (nonatomic, strong) NSLayoutConstraint *collapseWidth;
/// 三段变化:文字淡出 → 宽度收纳成圆形 → 中心出现旋转圆环
- (void)startLoading;
- (void)stopLoading;
@end

@implementation SparksCapsuleButton {
    UIStackView *_btInner;      // 图标 + 文字
    UIView *_btPlate;           // 底色层(渐变/描边)
    CAShapeLayer *_btRing;      // 加载圆环
    BOOL _btLoading;
    CGFloat _btRestWidth;       // 收纳前的宽度
}

- (instancetype)initWithTitle:(NSString *)title icon:(NSString *)sysImageName primary:(BOOL)primary {
    self = [super initWithFrame:CGRectMake(0, 0, 200, 48)];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.layer.cornerRadius = 24;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.shadowColor = primary ? SpAccent().CGColor : [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = primary ? 0.45 : 0.28;
        self.layer.shadowRadius = 10;
        self.layer.shadowOffset = CGSizeMake(0, 5);

        // 液态玻璃风:主按钮=主题色渐变+对比字色(v2.14 跟随主题);次按钮=玻璃白+描边;纯视觉层关交互
        UIView *plate = [[UIView alloc] init];
        if (primary) {
            // 从主题色推导渐变端点:亮端=accent,暗端=压暗 30%;文字按亮度选深/浅(全不透明,不再发淡)
            UIColor *acc = SpAccent();
            CGFloat r = 0, g = 0, b = 0, a = 0;
            [acc getRed:&r green:&g blue:&b alpha:&a];
            double lum = 0.299 * r + 0.587 * g + 0.114 * b;
            UIColor *onAcc = (lum > 0.55) ? [UIColor colorWithWhite:0.09 alpha:1.0]
                                          : [UIColor colorWithWhite:1.0 alpha:0.96];
            objc_setAssociatedObject(self, "ontint", onAcc, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CAGradientLayer *grad = [CAGradientLayer layer];
            grad.colors = @[(id)[UIColor colorWithRed:r green:g blue:b alpha:1].CGColor,
                            (id)[UIColor colorWithRed:r * 0.70 green:g * 0.70 blue:b * 0.70 alpha:1].CGColor];
            grad.startPoint = CGPointMake(0, 0);
            grad.endPoint = CGPointMake(1, 1);
            grad.cornerRadius = 14;
            grad.frame = CGRectMake(0, 0, 200, 48);   // 占位,尺寸由 layoutSubviews 校正
            [plate.layer addSublayer:grad];
            objc_setAssociatedObject(self, "grad", grad, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            plate.backgroundColor = [UIColor colorWithWhite:1 alpha:0.13];
            plate.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
            plate.layer.borderWidth = 1;
        }
        plate.layer.cornerRadius = 14;
        plate.layer.cornerCurve = kCACornerCurveContinuous;
        plate.userInteractionEnabled = NO;
        plate.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:plate];
        [NSLayoutConstraint activateConstraints:@[
            [plate.topAnchor constraintEqualToAnchor:self.topAnchor],
            [plate.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [plate.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [plate.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];

        UIStackView *inner = [[UIStackView alloc] init];
        inner.axis = UILayoutConstraintAxisHorizontal;
        inner.spacing = 8;
        inner.translatesAutoresizingMaskIntoConstraints = NO;
        [plate addSubview:inner];
        [NSLayoutConstraint activateConstraints:@[
            [inner.centerXAnchor constraintEqualToAnchor:plate.centerXAnchor],
            [inner.centerYAnchor constraintEqualToAnchor:plate.centerYAnchor],
        ]];

        if (sysImageName.length) {
            UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:sysImageName]];
            iv.contentMode = UIViewContentModeScaleAspectFit;
            iv.tintColor = primary ? (objc_getAssociatedObject(self, "ontint") ?: SpW(0.16)) : SpW(0.92);
            iv.translatesAutoresizingMaskIntoConstraints = NO;
            [inner addArrangedSubview:iv];
            [iv.widthAnchor constraintEqualToConstant:18].active = YES;
            [iv.heightAnchor constraintEqualToConstant:18].active = YES;
        }
        UILabel *label = [[UILabel alloc] init];
        label.text = title;
        label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        label.textColor = primary ? (objc_getAssociatedObject(self, "ontint") ?: SpW(0.16)) : [UIColor whiteColor];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [inner addArrangedSubview:label];

        _btInner = inner;
        _btPlate = plate;
        [self.heightAnchor constraintEqualToConstant:48].active = YES;

        [self addTarget:self action:@selector(spPressedDown) forControlEvents:UIControlEventTouchDown];
        [self addTarget:self action:@selector(spPressedUp)
                  forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [self addTarget:self action:@selector(spTapped) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CAGradientLayer *grad = objc_getAssociatedObject(self, "grad");
    if (grad) grad.frame = self.bounds;
    // 发热四轮:阴影固定路径,按下/弹起动画不再逐帧离屏重算
    if (!CGRectIsEmpty(self.bounds)) {
        self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                            byRoundingCorners:UIRectCornerAllCorners
                                                                  cornerRadii:CGSizeMake(14, 14)].CGPath;
    }
}

#pragma mark 三段变化:文字淡出 → 收成圆 → 旋转圆环

- (void)startLoading {
    if (_btLoading) return;
    _btLoading = YES;
    self.enabled = NO;   // 加载中不再响应点击

    // ① 文字/图标淡出
    [UIView animateWithDuration:0.14 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self->_btInner.alpha = 0;
        self->_btInner.transform = CGAffineTransformMakeScale(0.86, 0.86);
    } completion:^(BOOL finished) {
        if (!self->_btLoading) return;
        // ② 宽度收纳成圆形:关掉满宽约束、打开 48 宽约束
        //(v2.23.2 修正:之前把 constant 当宽度写,等于"父宽 + 48",按钮反而变宽,动画等于没发生)
        if (self.collapseWidth) {
            self.stretchWidth.active = NO;
            self.collapseWidth.active = YES;
        }

        CABasicAnimation *round = [CABasicAnimation animationWithKeyPath:@"cornerRadius"];
        round.fromValue = @(self->_btPlate.layer.cornerRadius);
        round.toValue = @24;
        round.duration = 0.28;
        round.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        self->_btPlate.layer.cornerRadius = 24;
        [self->_btPlate.layer addAnimation:round forKey:@"spRound"];

        [UIView animateWithDuration:0.28 delay:0
             usingSpringWithDamping:0.84 initialSpringVelocity:0.4
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:^{ [self.superview layoutIfNeeded]; }
                         completion:^(BOOL done) {
            if (!self->_btLoading) return;
            [self spShowRing];   // ③ 中心出现旋转圆环
        }];
    }];
}

- (void)spShowRing {
    CGSize size = self.bounds.size;
    if (!_btRing) {
        _btRing = [CAShapeLayer layer];
        _btRing.fillColor = UIColor.clearColor.CGColor;
        _btRing.lineWidth = 2.5;
        _btRing.lineCap = kCALineCapRound;
        _btRing.strokeEnd = 0.72;
        _btRing.opacity = 0;
        [self.layer addSublayer:_btRing];
    }
    _btRing.frame = CGRectMake(0, 0, size.width, size.height);
    CGFloat radius = MIN(size.width, size.height) / 2 - 6;
    _btRing.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(size.width / 2, size.height / 2)
                                                  radius:MAX(6, radius)
                                              startAngle:-M_PI_2
                                                endAngle:M_PI_2 * 3
                                               clockwise:YES].CGPath;
    UIColor *tint = objc_getAssociatedObject(self, "ontint") ?: [UIColor whiteColor];
    _btRing.strokeColor = tint.CGColor;
    [_btRing removeAnimationForKey:@"spSpin"];
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @0;
    spin.toValue = @(M_PI * 2);
    spin.duration = 0.9;
    spin.repeatCount = HUGE_VALF;
    [_btRing addAnimation:spin forKey:@"spSpin"];
    [UIView animateWithDuration:0.18 animations:^{ self->_btRing.opacity = 1; }];
}

- (void)stopLoading {
    if (!_btLoading) return;
    _btLoading = NO;
    [_btRing removeAnimationForKey:@"spSpin"];
    _btRing.opacity = 0;
    if (self.collapseWidth) {
        self.collapseWidth.active = NO;
        self.stretchWidth.active = YES;
    }
    _btPlate.layer.cornerRadius = 14;
    [UIView animateWithDuration:0.22 animations:^{
        self->_btInner.alpha = 1;
        self->_btInner.transform = CGAffineTransformIdentity;
        [self.superview layoutIfNeeded];
    } completion:^(BOOL finished) {
        self.enabled = YES;
    }];
}

- (void)spPressedDown {
    self.transform = CGAffineTransformMakeScale(0.95, 0.95);
}

- (void)spPressedUp {
    [UIView animateWithDuration:0.22 delay:0
         usingSpringWithDamping:0.5 initialSpringVelocity:0.6
                        options:0 animations:^{
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)spTapped {
    if (self.onTap) self.onTap();
}

@end

#pragma mark - 输入行

static UIView *spAddRowTile(UIView *row, NSString *title);

@interface SparksFieldRow : UIView <UITextFieldDelegate>
- (instancetype)initWithTitle:(NSString *)title
                   placeholder:(NSString *)ph
                        secure:(BOOL)secure
                           text:(NSString *)text
                       onChange:(void (^)(NSString *text))onChange;
@end

@implementation SparksFieldRow {
    UITextField *_tf;
    void (^_onChange)(NSString *);
    NSString *_lastText;   // 变更门:未改动文本的结束编辑不回调(避免无谓保存/面板重建)
}

- (instancetype)initWithTitle:(NSString *)title placeholder:(NSString *)ph secure:(BOOL)secure
                         text:(NSString *)text onChange:(void (^)(NSString *))onChange {
    self = [super initWithFrame:CGRectMake(0, 0, 320, 52)];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _onChange = [onChange copy];
        _lastText = text ?: @"";

        spAddRowTile(self, title);
        UILabel *label = SpMakeTitleLabel(title, 13);
        [self addSubview:label];
        [label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:58].active = YES;
        [label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor].active = YES;
        [label.widthAnchor constraintLessThanOrEqualToConstant:104].active = YES;

        _tf = [[UITextField alloc] init];
        _tf.placeholder = ph;
        _tf.text = text;
        _tf.secureTextEntry = secure;
        _tf.delegate = self;
        _tf.font = [UIFont systemFontOfSize:14];
        _tf.textColor = [UIColor whiteColor];
        _tf.textAlignment = NSTextAlignmentRight;
        _tf.returnKeyType = UIReturnKeyDone;
        _tf.autocorrectionType = UITextAutocorrectionTypeNo;
        _tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _tf.translatesAutoresizingMaskIntoConstraints = NO;
        _tf.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        _tf.layer.cornerRadius = 10;
        _tf.layer.cornerCurve = kCACornerCurveContinuous;
        UIView *padL = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)];
        _tf.leftView = padL;
        _tf.leftViewMode = UITextFieldViewModeAlways;
        UIView *padR = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)];
        _tf.rightView = padR;
        _tf.rightViewMode = UITextFieldViewModeAlways;
        [self addSubview:_tf];
        [_tf.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:10].active = YES;
        [_tf.trailingAnchor constraintEqualToAnchor:self.trailingAnchor].active = YES;
        [_tf.centerYAnchor constraintEqualToAnchor:self.centerYAnchor].active = YES;
        [_tf.heightAnchor constraintEqualToConstant:34].active = YES;

        [self.heightAnchor constraintEqualToConstant:52].active = YES;
    }
    return self;
}

- (void)textFieldDidBeginEditing:(UITextField *)tf {
    gEditingFields += 1;
}

- (void)textFieldDidEndEditing:(UITextField *)tf {
    gEditingFields = MAX(0, gEditingFields - 1);
    NSString *now = tf.text ?: @"";
    if (_onChange && ![now isEqualToString:(_lastText ?: @"")]) {
        _lastText = now;
        _onChange(now);
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

@end

#pragma mark - 信息行(纯展示 / 开关 / 可点击)

// iOS 设置风格:行首彩色圆角小方块图标(按标题关键词自动匹配)
static NSDictionary *spBadge(NSString *icon, UIColor *color) {
    return @{@"i": icon, @"c": color};
}
static NSDictionary *spRowBadge(NSString *title) {
    NSString *t = title.lowercaseString;
    if ([t containsString:@"校准"] || [t containsString:@"模板"]) return spBadge(@"checkmark.seal.fill", [UIColor systemBlueColor]);
    if ([t containsString:@"总开关"]) return spBadge(@"power", [UIColor systemGreenColor]);
    if ([t containsString:@"媒体"] || [t containsString:@"图片"] || [t containsString:@"语音"]) return spBadge(@"photo.on.rectangle.angled", [UIColor systemTealColor]);
    if ([t containsString:@"头像"] || [t containsString:@"昵称"] || [t containsString:@"资料"]) return spBadge(@"person.crop.circle.fill", [UIColor systemBlueColor]);
    if ([t containsString:@"时间"] || [t containsString:@"时段"]) return spBadge(@"clock.fill", [UIColor systemOrangeColor]);
    if ([t containsString:@"间隔"]) return spBadge(@"timer", [UIColor systemOrangeColor]);
    if ([t containsString:@"ai"] || [t containsString:@"接口"] || [t containsString:@"预设"]) return spBadge(@"wand.and.stars", [UIColor systemPurpleColor]);
    if ([t containsString:@"外观"] || [t containsString:@"材质"] || [t containsString:@"主题"] || [t containsString:@"玻璃"] || [t containsString:@"磨砂"] || [t containsString:@"动画"]) return spBadge(@"paintbrush.fill", [UIColor systemPinkColor]);
    if ([t containsString:@"保活"] || [t containsString:@"后台"]) return spBadge(@"moon.fill", [UIColor systemIndigoColor]);
    if ([t containsString:@"更新"]) return spBadge(@"arrow.down.circle.fill", [UIColor systemGreenColor]);
    if ([t containsString:@"捐赠"] || [t containsString:@"赞赏"]) return spBadge(@"heart.fill", [UIColor systemPinkColor]);
    if ([t containsString:@"备份"] || [t containsString:@"恢复"]) return spBadge(@"arrow.uturn.left.circle.fill", [UIColor systemGrayColor]);
    if ([t containsString:@"日志"]) return spBadge(@"doc.text.fill", [UIColor systemGrayColor]);
    if ([t containsString:@"悬浮球"]) return spBadge(@"circle.circle.fill", [UIColor systemBlueColor]);
    if ([t containsString:@"面板"] || [t containsString:@"底衬"] || [t containsString:@"背景"]) return spBadge(@"rectangle.on.rectangle.angled", [UIColor systemTealColor]);
    if ([t containsString:@"浮条"] || [t containsString:@"提示"]) return spBadge(@"bubble.left.and.bubble.right.fill", [UIColor systemTealColor]);
    if ([t containsString:@"id"] || [t containsString:@"签名"]) return spBadge(@"person.text.rectangle.fill", [UIColor systemGrayColor]);
    if ([t containsString:@"间隔"]) return spBadge(@"timer", [UIColor systemOrangeColor]);
    if ([t containsString:@"字体"]) return spBadge(@"textformat", [UIColor systemPinkColor]);
    if ([t containsString:@"文案"] || [t containsString:@"兜底"]) return spBadge(@"text.quote", [UIColor systemGrayColor]);
    if ([t containsString:@"key"] || [t containsString:@"密钥"]) return spBadge(@"key", [UIColor systemPurpleColor]);
    if ([t containsString:@"模型"]) return spBadge(@"cpu", [UIColor systemPurpleColor]);
    if ([t containsString:@"链接"] || [t containsString:@"地址"]) return spBadge(@"link", [UIColor systemBlueColor]);
    // 兜底:未匹配也给通用方块,保证每行文字左缘对齐不错位
    return spBadge(@"slider.horizontal.3", nil);
}

// 行首 30pt 玻璃白块图标:InfoRow/FieldRow 共用,标题文字左缘统一 58pt(16+30+12)
static UIView *spAddRowTile(UIView *row, NSString *title) {
    NSDictionary *badge = spRowBadge(title);
    UIView *tile = [[UIView alloc] init];
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    tile.layer.cornerRadius = 7;
    tile.layer.cornerCurve = kCACornerCurveContinuous;
    tile.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];   // 玻璃白块
    tile.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    tile.layer.borderWidth = 1;
    UIImageView *ic = [[UIImageView alloc] initWithImage:
                       [UIImage systemImageNamed:badge[@"i"]]];
    ic.contentMode = UIViewContentModeScaleAspectFit;
    ic.tintColor = SpW(0.92);   // 暖白图标
    ic.translatesAutoresizingMaskIntoConstraints = NO;
    [tile addSubview:ic];
    [ic.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor].active = YES;
    [ic.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor].active = YES;
    [ic.widthAnchor constraintEqualToConstant:17].active = YES;
    [ic.heightAnchor constraintEqualToConstant:17].active = YES;
    [row addSubview:tile];
    [tile.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16].active = YES;
    [tile.centerYAnchor constraintEqualToAnchor:row.centerYAnchor].active = YES;
    [tile.widthAnchor constraintEqualToConstant:30].active = YES;
    [tile.heightAnchor constraintEqualToConstant:30].active = YES;
    return tile;
}

@interface SparksInfoRow : UIView
+ (instancetype)infoWithTitle:(NSString *)title value:(NSString *)value;
+ (instancetype)switchWithTitle:(NSString *)title on:(BOOL)on
                       onChange:(void (^)(BOOL on))onChange;
+ (instancetype)actionWithTitle:(NSString *)title value:(NSString *)value
                          onTap:(void (^)(void))onTap;
@end

@implementation SparksInfoRow

- (void)commonInitWithTitle:(NSString *)title value:(NSString *)value {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    CGFloat leadPad = 58;
    spAddRowTile(self, title);

    UIStackView *left = [[UIStackView alloc] init];
    left.axis = UILayoutConstraintAxisVertical;
    left.spacing = 2;
    left.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:left];
    UILabel *tl = [[UILabel alloc] init];
    tl.text = title;
    tl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    tl.textColor = SpTitleColor();   // v2.14:行标题跟主题色(字体跟随开关,默认开)
    [left addArrangedSubview:tl];
    if (value.length) [left addArrangedSubview:SpMakeSubLabel(value)];
    [left.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:leadPad].active = YES;
    [left.centerYAnchor constraintEqualToAnchor:self.centerYAnchor].active = YES;
    [self.heightAnchor constraintEqualToConstant:value.length ? 58 : 52].active = YES;
}

+ (instancetype)infoWithTitle:(NSString *)title value:(NSString *)value {
    SparksInfoRow *row = [[SparksInfoRow alloc] initWithFrame:CGRectMake(0, 0, 320, 46)];
    [row commonInitWithTitle:title value:value];
    return row;
}

+ (instancetype)switchWithTitle:(NSString *)title on:(BOOL)on
                       onChange:(void (^)(BOOL))onChange {
    SparksInfoRow *row = [[SparksInfoRow alloc] initWithFrame:CGRectMake(0, 0, 320, 46)];
    [row commonInitWithTitle:title value:nil];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.onTintColor = SpAccent();
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:sw];
    [sw.trailingAnchor constraintEqualToAnchor:row.trailingAnchor].active = YES;
    [sw.centerYAnchor constraintEqualToAnchor:row.centerYAnchor].active = YES;
    [sw addTarget:row action:@selector(spSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(row, "sw", sw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(row, "cb", [onChange copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return row;
}

+ (instancetype)actionWithTitle:(NSString *)title value:(NSString *)value
                          onTap:(void (^)(void))onTap {
    SparksInfoRow *row = [[SparksInfoRow alloc] initWithFrame:CGRectMake(0, 0, 320, 46)];
    [row commonInitWithTitle:title value:value];

    UIImageView *chev = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chev.tintColor = SpW(0.55);
    chev.contentMode = UIViewContentModeScaleAspectFit;
    chev.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:chev];
    [chev.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:2].active = YES;
    [chev.centerYAnchor constraintEqualToAnchor:row.centerYAnchor].active = YES;
    [chev.widthAnchor constraintEqualToConstant:12].active = YES;
    [chev.heightAnchor constraintEqualToConstant:12].active = YES;

    objc_setAssociatedObject(row, "cb", [onTap copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (onTap) {
        row.userInteractionEnabled = YES;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:row action:@selector(spRowTapped)];
        [row addGestureRecognizer:tap];
    }
    return row;
}

- (void)spSwitchChanged:(UISwitch *)sw {
    void (^cb)(BOOL) = objc_getAssociatedObject(self, "cb");
    if (cb) cb(sw.on);
}

- (void)spRowTapped {
    void (^cb)(void) = objc_getAssociatedObject(self, "cb");
    if (cb) cb();
}

@end

#pragma mark - 状态行(彩色 SF Symbol 图标)

@interface SparksStatusRow : UIView
+ (instancetype)rowWithTitle:(NSString *)title value:(NSString *)value
                       icon:(NSString *)sysImage color:(UIColor *)color;
@end

@implementation SparksStatusRow

+ (instancetype)rowWithTitle:(NSString *)title value:(NSString *)value
                       icon:(NSString *)sysImage color:(UIColor *)color {
    SparksStatusRow *row = [[SparksStatusRow alloc] initWithFrame:CGRectMake(0, 0, 320, 46)];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *tile = [[UIView alloc] init];
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    tile.layer.cornerRadius = 7;
    tile.layer.cornerCurve = kCACornerCurveContinuous;
    tile.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    tile.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    tile.layer.borderWidth = 1;
    UIImageView *ic = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:sysImage]];
    ic.tintColor = color;   // 语义色移到图标
    ic.contentMode = UIViewContentModeScaleAspectFit;
    ic.translatesAutoresizingMaskIntoConstraints = NO;
    [tile addSubview:ic];
    [ic.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor].active = YES;
    [ic.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor].active = YES;
    [ic.widthAnchor constraintEqualToConstant:17].active = YES;
    [ic.heightAnchor constraintEqualToConstant:17].active = YES;
    [row addSubview:tile];
    [tile.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16].active = YES;
    [tile.centerYAnchor constraintEqualToAnchor:row.centerYAnchor].active = YES;
    [tile.widthAnchor constraintEqualToConstant:30].active = YES;
    [tile.heightAnchor constraintEqualToConstant:30].active = YES;

    UIStackView *mid = [[UIStackView alloc] init];
    mid.axis = UILayoutConstraintAxisVertical;
    mid.spacing = 2;
    mid.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:mid];
    [mid addArrangedSubview:SpMakeTitleLabel(title, 16)];   // SpMakeTitleLabel 已走 SpTitleColor
    if (value.length) [mid addArrangedSubview:SpMakeSubLabel(value)];
    [mid.leadingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:12].active = YES;
    [mid.centerYAnchor constraintEqualToAnchor:row.centerYAnchor].active = YES;
    [row.heightAnchor constraintEqualToConstant:value.length ? 52 : 46].active = YES;
    return row;
}

@end

#pragma mark - 自定义分段控件(玻璃选中胶囊)

// 触控外扩:整个条与每个页签都向四周多接 10pt(44pt 条实际接 64pt 高)
#define SP_SEG_TOUCH_INSET 10

@interface SparksGlassSeg : UIControl
- (instancetype)initWithTitles:(NSArray<NSString *> *)titles
                     selection:(void (^)(NSInteger idx))sel;
- (void)setIndex:(NSInteger)i animated:(BOOL)animated;
@property (nonatomic, assign, readonly) NSInteger index;
@end

// 页签按钮:触控区外扩 10pt(点条边缘/间隙也能命中)
@interface SparksSegTab : UIControl
@end
@implementation SparksSegTab
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    UIEdgeInsets pad = UIEdgeInsetsMake(-SP_SEG_TOUCH_INSET, -SP_SEG_TOUCH_INSET, -SP_SEG_TOUCH_INSET, -SP_SEG_TOUCH_INSET);
    return CGRectContainsPoint(UIEdgeInsetsInsetRect(self.bounds, pad), point);
}
@end

@implementation SparksGlassSeg {
    UIView *_barWrap;   // 底条容器(玻璃或实底)
    NSArray<SparksSegTab *> *_tabs;
    NSArray<UIImageView *> *_icons;
    NSArray<UIView *> *_dots;
    NSArray<UILabel *> *_labels;
    NSArray<NSString *> *_titles;
    void (^_sel)(NSInteger);
    NSInteger _index;
    BOOL _usePill;      // 风格 0/1 才有选中胶囊
    BOOL _showLabels;   // 风格 1/2/3 图标下带文字
}

// 五个页签的图标(顺序与 titles 对应)
+ (NSArray<NSString *> *)spIcons {
    return @[@"flame.fill", @"person.2.fill", @"paintpalette.fill", @"gearshape.fill", @"list.bullet.rectangle"];
}

- (instancetype)initWithTitles:(NSArray<NSString *> *)titles
                     selection:(void (^)(NSInteger idx))sel {
    self = [super initWithFrame:CGRectMake(0, 0, 320, 50)];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        // v2.22.0:只剩控制台一套 dock(近黑实底 + 主题色胶囊 + 文字标签)
        self.backgroundColor = [UIColor clearColor];
        _usePill = YES;
        _showLabels = YES;
        UIView *bar = [[UIView alloc] init];
        bar.translatesAutoresizingMaskIntoConstraints = NO;
        bar.userInteractionEnabled = NO;
        bar.layer.cornerRadius = 20;
        bar.layer.cornerCurve = kCACornerCurveContinuous;
        bar.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.94];
        bar.layer.borderWidth = 1;
        bar.layer.borderColor = SpCardStroke().CGColor;
        _barWrap = bar;
        [self addSubview:bar];
        [NSLayoutConstraint activateConstraints:@[
            [_barWrap.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_barWrap.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_barWrap.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_barWrap.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];

        _titles = titles;
        _sel = [sel copy];
        _index = 0;

        NSArray<NSString *> *icons = [SparksGlassSeg spIcons];
        NSMutableArray *tabs = [NSMutableArray array];
        NSMutableArray *iconsA = [NSMutableArray array];
        NSMutableArray *dotsA = [NSMutableArray array];
        NSMutableArray *labelsA = [NSMutableArray array];
        for (NSUInteger i = 0; i < titles.count; i++) {
            SparksSegTab *t = [[SparksSegTab alloc] init];
            t.tag = i;

            // 选中胶囊:玻璃风格=白色浮起圆片;控制台=主题色染底;卡片流/清单不要胶囊
            UIView *wrap = [[UIView alloc] init];
            wrap.layer.cornerRadius = 16;
            wrap.layer.cornerCurve = kCACornerCurveContinuous;
            wrap.backgroundColor = [SpAccent() colorWithAlphaComponent:0.18];
            wrap.hidden = YES;
            wrap.userInteractionEnabled = NO;
            wrap.translatesAutoresizingMaskIntoConstraints = NO;
            [t addSubview:wrap];
            [wrap.centerXAnchor constraintEqualToAnchor:t.centerXAnchor].active = YES;
            [wrap.centerYAnchor constraintEqualToAnchor:t.centerYAnchor].active = YES;
            [wrap.widthAnchor constraintEqualToConstant:52].active = YES;
            [wrap.heightAnchor constraintEqualToConstant:34].active = YES;
            objc_setAssociatedObject(t, "wrap", wrap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            UIImageView *ic = [[UIImageView alloc] initWithImage:
                               [UIImage systemImageNamed:(i < icons.count ? icons[i] : @"circle.fill")]];
            ic.contentMode = UIViewContentModeScaleAspectFit;
            ic.tintColor = SpW(0.55);
            ic.translatesAutoresizingMaskIntoConstraints = NO;
            [t addSubview:ic];
            // 带文字的风格把图标上抬,给下方 9pt 标签让位
            CGFloat iconSide = _showLabels ? 19 : 20;
            [ic.centerXAnchor constraintEqualToAnchor:t.centerXAnchor].active = YES;
            [ic.centerYAnchor constraintEqualToAnchor:t.centerYAnchor
                                             constant:_showLabels ? -7 : 0].active = YES;
            [ic.widthAnchor constraintEqualToConstant:iconSide].active = YES;
            [ic.heightAnchor constraintEqualToConstant:iconSide].active = YES;

            UILabel *lb = nil;
            if (_showLabels) {
                lb = [[UILabel alloc] init];
                lb.text = titles[i];
                lb.font = [UIFont systemFontOfSize:9 weight:UIFontWeightMedium];
                lb.textColor = SpW(0.55);
                lb.textAlignment = NSTextAlignmentCenter;
                lb.userInteractionEnabled = NO;
                lb.translatesAutoresizingMaskIntoConstraints = NO;
                [t addSubview:lb];
                [lb.centerXAnchor constraintEqualToAnchor:t.centerXAnchor].active = YES;
                [lb.topAnchor constraintEqualToAnchor:ic.bottomAnchor constant:1].active = YES;
            }
            [labelsA addObject:lb ?: (UILabel *)[NSNull null]];


            [t addTarget:self action:@selector(spTabTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:t];
            [tabs addObject:t];
            [iconsA addObject:ic];
        }
        _tabs = tabs;
        _icons = iconsA;
        _dots = dotsA;
        _labels = labelsA;
        [self setIndex:0 animated:NO];
    }
    return self;
}

- (void)spTabTapped:(SparksSegTab *)t {
    [self setIndex:t.tag animated:YES];
    if (_sel) _sel(t.tag);
}

- (NSInteger)index {
    return _index;
}

- (void)setIndex:(NSInteger)i animated:(BOOL)animated {
    _index = i;
    void (^apply)(void) = ^{
        UIColor *idle = SpW(0.55);
        for (NSUInteger k = 0; k < self->_tabs.count; k++) {
            BOOL on = ((NSInteger)k == self->_index);
            UIView *wrap = objc_getAssociatedObject(self->_tabs[k], "wrap");
            wrap.hidden = !(on && self->_usePill);
            self->_icons[k].tintColor = on ? SpAccent() : idle;   // 选中图标跟主题色
            if (k < self->_dots.count && self->_dots[k].superview) {
                self->_dots[k].backgroundColor = on ? SpAccent() : [UIColor clearColor];
            }
            if (k < self->_labels.count && [self->_labels[k] isKindOfClass:[UILabel class]]) {
                ((UILabel *)self->_labels[k]).textColor = on ? SpAccent() : idle;
            }
        }
    };
    if (animated && _usePill) {
        // 圆片淡入浮起
        UIView *wrap = objc_getAssociatedObject(_tabs[i], "wrap");
        wrap.transform = CGAffineTransformMakeScale(0.7, 0.7);
        wrap.alpha = 0;
        apply();
        [UIView animateWithDuration:0.32 delay:0
             usingSpringWithDamping:0.72 initialSpringVelocity:0.5
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            wrap.transform = CGAffineTransformIdentity;
            wrap.alpha = 1;
        } completion:nil];
    } else {
        apply();
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    NSUInteger n = _titles.count;
    if (!n) return;
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat bw = w / n;
    for (SparksSegTab *t in _tabs) {
        t.frame = CGRectMake(t.tag * bw, 0, bw, h);
    }
}

// 触控外扩:整个条与每个页签都向四周多接 10pt(44pt 条实际接 64pt 高)
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    UIEdgeInsets pad = UIEdgeInsetsMake(-SP_SEG_TOUCH_INSET, -SP_SEG_TOUCH_INSET, -SP_SEG_TOUCH_INSET, -SP_SEG_TOUCH_INSET);
    return CGRectContainsPoint(UIEdgeInsetsInsetRect(self.bounds, pad), point);
}

@end

#pragma mark - 穿透窗口

@interface SparksPanel ()   // 内部属性前置声明(hitTest 需要)
@property (nonatomic, strong) UIView *ballWrapper;
@property (nonatomic, strong) UIView *panelRoot;
@property (nonatomic, strong) UIView *backgroundTapView;
@property (nonatomic, strong) UIView *donateView;
@property (nonatomic, assign) BOOL animateNextBuild;   // 下次重建后播放入场动效
@property (nonatomic, weak) SparksCapsuleButton *busyButton;   // 正在播放三段动画的按钮:期间冻结内容重建
@property (nonatomic, assign) BOOL targetsManaging;   // 目标页:是否切到"管理"(删除/单独设置)模式
@property (nonatomic, copy) NSString *detailKey;      // 目标单独设置页:正在查看的目标 key(空=列表)
@end

@interface SparksPanel (Internal)
+ (BOOL)isOwnedSubview:(UIView *)v;
+ (SparksPanel *)spShared;
- (void)outsideTapped;
@end

@interface SparksHitWindow : UIWindow
@end

@implementation SparksHitWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    SparksPanel *panel = [SparksPanel spShared];
    // 本窗口顶层正呈现弹窗/相册/取色器/分享:触摸交给真实命中视图
    // (面板开或关都要放行,否则弹窗收不到点击)
    if (self.rootViewController && self.rootViewController.presentedViewController) {
        return [super hitTest:point withEvent:event];
    }
    UIView *hit = [super hitTest:point withEvent:event];
    UIView *v = hit;
    while (v) {
        if (v == panel.ballWrapper || v == panel.panelRoot || v == panel.donateView) return hit;
        v = v.superview;
    }
    // 面板打开时:面板外触摸落到背景捕获层(点击关闭);未打开:完全穿透
    if (panel.panelRoot.superview && panel.backgroundTapView) {
        return panel.backgroundTapView;
    }
    return nil;
}

@end

#pragma mark - 面板

@interface SparksPanel () <PHPickerViewControllerDelegate, UIColorPickerViewControllerDelegate>
@property (nonatomic, strong) SparksHitWindow *panelWindow;
@property (nonatomic, strong) UIView *ballIconHolder;        // 球图标容器(透明背景)
@property (nonatomic, strong) UIView *panelBackdropView;
@property (nonatomic, strong) UIImageView *panelBgView;
@property (nonatomic, strong) UIView *panelDimView;
@property (nonatomic, strong) SparksGlassSeg *seg;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) NSTimer *logTimer;
@property (nonatomic, assign) NSInteger tab;
@property (nonatomic, copy) NSString *lastSig;
// 成功提示浮条
@property (nonatomic, strong) UIView *toastView;
@property (nonatomic, strong) UILabel *toastLabel;
@property (nonatomic, strong) NSTimer *toastHideTimer;
// 相册选择
@property (nonatomic, copy) NSString *pickPrefix;
@property (nonatomic, copy) void (^pickDone)(NSString *path);
@property (nonatomic, assign) BOOL pickMediaMulti;
// 方法前置声明(定义在文件后段,前段 build/hook 回调会先引用)
- (void)scheduleRebuild;
- (void)scheduleRebuildIfChanged;
- (void)rebuildContent;
- (void)refreshLog;
- (void)refreshChrome;
- (void)spAnimateStackEntries;
- (void)spBuildConsoleTab;
- (void)spBuildConsoleMetrics;
- (void)spBuildConsoleButton;
- (void)spBuildConsoleOps;
- (UIStackView *)spConsoleRow:(NSArray<UIView *> *)tiles;
- (void)applyAvatarInto:(UIView *)avatar;
- (void)applyPanelBackground;
- (void)segChangedTo:(NSInteger)idx;
- (void)openPanel;
- (void)closePanel;
- (UIViewController *)topVC;
@end

@implementation SparksPanel

+ (BOOL)isOwnedSubview:(UIView *)v {
    SparksPanel *p = [self spShared];
    return v == p.ballWrapper || v == p.panelRoot || v == p.toastView;
}

+ (SparksPanel *)spShared {
    return (SparksPanel *)[SparksPanel shared];
}

+ (instancetype)shared {
    static SparksPanel *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[SparksPanel alloc] init]; });
    return s;
}

- (void)setup {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self createBall];
        __weak typeof(self) ws = self;
        [SparksEngine shared].onStateChange = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) s = ws;
                if (!s) return;
                [s scheduleRebuildIfChanged];
                if (s.tab == 4) [s refreshLog];
            });
        };
        [[NSNotificationCenter defaultCenter] addObserverForName:SparksToastNote
                                                          object:nil queue:nil
                                                     usingBlock:^(NSNotification *n) {
            NSString *text = n.userInfo[@"text"];
            if (text.length) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) s = ws;
                    if (s) [s showToast:text];
                });
            }
        }];
    });
}

#pragma mark - 悬浮球(透明背景,无阴影,松手贴边;面板打开时隐藏)

- (void)createBall {
    if (self.ballWrapper) return;
    CGFloat size = [self currentBallSize];

    // 透明背景:无描边无阴影,仅图标(材质不影响球)
    UIView *wrapper = [[UIView alloc] initWithFrame:CGRectMake([UIScreen mainScreen].bounds.size.width - size - 16, 220, size, size)];
    wrapper.layer.cornerRadius = size / 2;
    wrapper.layer.cornerCurve = kCACornerCurveContinuous;

    UIView *holder = [[UIView alloc] initWithFrame:wrapper.bounds];
    holder.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    holder.userInteractionEnabled = NO;
    holder.layer.cornerRadius = size / 2;
    holder.layer.cornerCurve = kCACornerCurveContinuous;
    holder.clipsToBounds = YES;
    [wrapper addSubview:holder];

    wrapper.userInteractionEnabled = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ballTapped)];
    [wrapper addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(ballPanned:)];
    [wrapper addGestureRecognizer:pan];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(ballLongPressed:)];
    lp.minimumPressDuration = 0.5;
    [wrapper addGestureRecognizer:lp];

    SparksHitWindow *w = [[SparksHitWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = UIWindowLevelStatusBar + 2;
    w.rootViewController = [UIViewController new];
    w.rootViewController.view.backgroundColor = [UIColor clearColor];
    w.rootViewController.view.userInteractionEnabled = YES;
    w.hidden = NO;

    UIView *bgTap = [[UIView alloc] initWithFrame:w.rootViewController.view.bounds];
    bgTap.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bgTap.backgroundColor = [UIColor clearColor];
    bgTap.userInteractionEnabled = YES;
    UITapGestureRecognizer *bgRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(outsideTapped)];
    [bgTap addGestureRecognizer:bgRecognizer];
    [w.rootViewController.view addSubview:bgTap];

    [w.rootViewController.view addSubview:wrapper];
    self.panelWindow = w;
    self.ballWrapper = wrapper;
    self.ballIconHolder = holder;
    self.backgroundTapView = bgTap;

    [self applyBallIcon];
}

- (CGFloat)currentBallSize {
    SparksConfig *cfg = [SparksConfig shared];
    return (cfg.ballSize >= 16 && cfg.ballSize <= 80) ? cfg.ballSize : 52;
}

// 重建图标内容(默认火焰 / 静态图片 / GIF)
- (void)applyBallIcon {
    UIView *holder = self.ballIconHolder;
    if (!holder) return;
    for (UIView *v in [holder.subviews copy]) {
        [v removeFromSuperview];
    }
    CGFloat w = holder.bounds.size.width;
    if (w <= 0) w = self.ballWrapper.bounds.size.width;
    holder.layer.cornerRadius = w / 2;   // 容器自裁圆,子视图无需各自圆角

    NSString *iconPath = [SparksConfig shared].ballIconPath;
    if (iconPath.length && [[NSFileManager defaultManager] fileExistsAtPath:iconPath]) {
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:iconPath], NULL);
        BOOL isGif = src && CGImageSourceGetCount(src) > 1;
        if (src) CFRelease(src);
        if (isGif) {
            SparksGifIconView *gif = [[SparksGifIconView alloc] initWithFilePath:iconPath];
            gif.frame = holder.bounds;
            gif.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [holder addSubview:gif];
            [self setBallGifPlaying:!self.panelRoot.superview];
            return;
        }
        UIImage *img = [UIImage imageWithContentsOfFile:iconPath];
        if (img) {
            UIImageView *iv = [[UIImageView alloc] initWithImage:img];
            iv.contentMode = UIViewContentModeScaleAspectFill;   // 居中裁切不变形
            iv.frame = holder.bounds;
            iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [holder addSubview:iv];
            return;
        }
        SparksLog(@"⚠️ 自定义图标解码失败,回退默认");
    }
    // 默认火焰:以 holder 坐标居中,四边弹性边距保证调大小后自动回中
    CGFloat iconSide = MAX(12, w * 0.55);
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"flame.fill"]];
    icon.tintColor = SpAccent();
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.frame = CGRectMake((w - iconSide) / 2, (w - iconSide) / 2, iconSide, iconSide);
    icon.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                          | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [holder addSubview:icon];
}

- (void)setBallGifPlaying:(BOOL)playing {
    for (UIView *v in self.ballIconHolder.subviews) {
        if ([v isKindOfClass:[SparksGifIconView class]]) {
            [(SparksGifIconView *)v setPlaying:playing];
        }
    }
}

// 调节大小(保持中心)
- (void)applyBallSize {
    UIView *wrapper = self.ballWrapper;
    if (!wrapper) return;
    CGFloat size = [self currentBallSize];
    CGPoint c = wrapper.center;
    CGRect b = [UIScreen mainScreen].bounds;
    c.x = MAX(size / 2 + 6, MIN(b.size.width - size / 2 - 6, c.x));
    c.y = MAX(64, MIN(b.size.height - 48, c.y));
    wrapper.layer.cornerRadius = size / 2;
    [UIView animateWithDuration:0.18 animations:^{
        wrapper.frame = CGRectMake(c.x - size / 2, c.y - size / 2, size, size);
    } completion:^(BOOL finished) {
        [self applyBallIcon];
    }];
}

- (void)ballPanned:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
    CGRect b = [UIScreen mainScreen].bounds;
    v.center = CGPointMake(MAX(26, MIN(b.size.width - 26, v.center.x)),
                           MAX(64, MIN(b.size.height - 48, v.center.y)));

    if (g.state == UIGestureRecognizerStateEnded) {
        CGFloat size = v.bounds.size.width;
        CGFloat margin = 6;
        CGFloat targetX = (v.center.x < b.size.width / 2) ? margin + size / 2 : b.size.width - margin - size / 2;
        CGFloat dir = targetX > v.center.x ? 0.5 : -0.5;
        [UIView animateWithDuration:0.35 delay:0
             usingSpringWithDamping:0.72 initialSpringVelocity:dir
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            v.center = CGPointMake(targetX, v.center.y);
        } completion:nil];
    }
}

- (void)ballTapped {
    UIView *wrapper = self.ballWrapper;
    wrapper.transform = CGAffineTransformMakeScale(0.88, 0.88);
    [UIView animateWithDuration:0.25 delay:0
         usingSpringWithDamping:0.5 initialSpringVelocity:0.7
                        options:0 animations:^{
        wrapper.transform = CGAffineTransformIdentity;
    } completion:nil];

    if (self.panelRoot.superview) [self closePanel];
    else [self openPanel];
}

// 长按菜单:悬浮球/设置 双入口
- (void)ballLongPressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    __weak typeof(self) ws = self;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"AI 续火花"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"打开面板" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        typeof(self) s = ws; if (s) [s openPanel];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"直达外观设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        typeof(self) s = ws; if (s) [s openPanelToTab:2];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"直达参数设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        typeof(self) s = ws; if (s) [s openPanelToTab:3];
    }]];
    NSString *toggle = [SparksConfig shared].master ? @"关闭续火花总开关" : @"开启续火花总开关";
    [ac addAction:[UIAlertAction actionWithTitle:toggle style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        SparksConfig *c = [SparksConfig shared];
        c.master = !c.master;
        [c save];
        SparksLog(@"总开关:%@", c.master ? @"开" : @"关");
        typeof(self) s = ws;
        if (s) [s scheduleRebuild];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *top = [self topVC];
    if (top) {
        ac.popoverPresentationController.sourceView = top.view;
        [top presentViewController:ac animated:YES completion:nil];
    }
}

- (void)openPanelToTab:(NSInteger)tab {
    [self openPanel];
    [self.seg setIndex:tab animated:NO];
    self.tab = tab;
    [self rebuildContent];
}

// 抖音设置页导航栏入口按钮回调
- (void)spOpenFromSettings {
    [self openPanelToTab:0];
}

// 面板外点击:一下直接关闭
- (void)outsideTapped {
    [self closePanel];
}

#pragma mark - 成功提示浮条(玻璃胶囊,可拖动调整位置)

- (void)showToast:(NSString *)text {
    SparksConfig *cfg = [SparksConfig shared];
    if (!cfg.toastOn) return;
    if (!self.panelWindow) return;

    if (!self.toastView) {
        UIView *tv = [[UIView alloc] init];
        tv.layer.cornerRadius = 15;
        tv.layer.cornerCurve = kCACornerCurveContinuous;
        tv.layer.shadowColor = [UIColor blackColor].CGColor;
        tv.layer.shadowOpacity = 0.3;
        tv.layer.shadowRadius = 10;
        tv.layer.shadowOffset = CGSizeMake(0, 4);
        tv.userInteractionEnabled = NO;   // 不可拖动调节,触摸直接穿透

        UIView *clip = [[UIView alloc] initWithFrame:tv.bounds];
        clip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        clip.backgroundColor = [UIColor colorWithRed:0.055 green:0.065 blue:0.115 alpha:0.92];
        clip.layer.cornerRadius = 15;
        clip.layer.cornerCurve = kCACornerCurveContinuous;
        [tv addSubview:clip];

        UILabel *l = [[UILabel alloc] init];
        l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        l.textColor = [UIColor whiteColor];
        l.textAlignment = NSTextAlignmentCenter;
        l.userInteractionEnabled = NO;
        [clip addSubview:l];

        self.toastView = tv;
        self.toastLabel = l;
    }
    self.toastLabel.text = text;
    // 按文字实际宽度收缩,更小巧;上限防溢出
    CGSize ts = [text boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                    options:NSStringDrawingUsesLineFragmentOrigin
                                 attributes:@{NSFontAttributeName: self.toastLabel.font} context:nil].size;
    CGRect b = self.panelWindow.bounds;
    CGFloat w = MIN(MAX(ts.width + 28, 96), b.size.width - 40);
    CGFloat y = cfg.toastOffsetY;
    self.toastView.frame = CGRectMake((b.size.width - w) / 2, y, w, 30);
    self.toastView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, w, 30)
                                                                cornerRadius:15].CGPath;   // 发热四轮:浮条阴影固定路径
    self.toastLabel.frame = CGRectMake(12, 0, w - 24, 30);
    [self.panelWindow.rootViewController.view addSubview:self.toastView];
    [self.panelWindow.rootViewController.view bringSubviewToFront:self.toastView];
    self.toastView.alpha = 0;
    self.toastView.transform = CGAffineTransformMakeScale(0.9, 0.9);
    [UIView animateWithDuration:0.25 delay:0
         usingSpringWithDamping:0.8 initialSpringVelocity:0.5
                        options:0 animations:^{
        self.toastView.alpha = 1;
        self.toastView.transform = CGAffineTransformIdentity;
    } completion:nil];

    [self.toastHideTimer invalidate];
    self.toastHideTimer = [NSTimer scheduledTimerWithTimeInterval:2.2 target:self
                                                         selector:@selector(hideToast) userInfo:nil repeats:NO];
}

- (void)hideToast {
    __weak typeof(self) ws = self;
    [UIView animateWithDuration:0.25 animations:^{
        typeof(self) s = ws;
        if (s) {
            s.toastView.alpha = 0;
            s.toastView.transform = CGAffineTransformMakeScale(0.9, 0.9);
        }
    } completion:^(BOOL finished) {
        typeof(self) s = ws;
        if (s) [s.toastView removeFromSuperview];
    }];
}

- (void)refreshLog {
    if (!self.logTextView) return;
    NSString *snap = SparksLogSnapshot();
    if (![self.logTextView.text isEqualToString:snap]) {
        self.logTextView.text = snap;
        if (snap.length) [self.logTextView scrollRangeToVisible:NSMakeRange(snap.length - 1, 1)];
    }
}

#pragma mark - 内容构建(合并刷新,输入中跳过)

- (void)refreshChrome {
    BOOL wasOpen = self.panelRoot.superview != nil;
    [self.logTimer invalidate];
    self.logTimer = nil;
    // 重建必须等关闭动画走完(动画时长随开合速率变化),否则新旧面板交接出竞态
    CGFloat d = 0.2 / MAX(0.3, [SparksConfig shared].animSpeed) + 0.15;
    [self closePanel];
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) s = ws;
        if (!s) return;
        s.panelRoot = nil;
        s.seg = nil;
        s.scroll = nil;
        s.stack = nil;
        s.logTextView = nil;
        s.panelBackdropView = nil;
        s.panelBgView = nil;
        s.panelDimView = nil;
        s.toastView = nil;
        s.toastLabel = nil;
        s.lastSig = nil;   // 骨架已重建,签名必须失效,否则重开后内容区空白
        [s applyBallIcon];
        // 重开守卫:等待期间用户主动关了面板(球已恢复显示)就不再弹回
        if (wasOpen && s.ballWrapper.hidden) [s openPanel];
    });
}

- (void)applyAvatarInto:(UIView *)avatar {
    for (UIView *v in [avatar.subviews copy]) [v removeFromSuperview];
    SparksConfig *cfg = [SparksConfig shared];
    NSString *path = cfg.avatarPath;
    if (path.length && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
        BOOL isGif = src && CGImageSourceGetCount(src) > 1;
        if (src) CFRelease(src);
        if (isGif) {
            SparksGifIconView *gif = [[SparksGifIconView alloc] initWithFilePath:path];
            gif.frame = avatar.bounds;
            gif.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [avatar addSubview:gif];
            return;
        }
        UIImage *img = [UIImage imageWithContentsOfFile:path];
        if (img) {
            UIImageView *iv = [[UIImageView alloc] initWithImage:img];
            iv.contentMode = UIViewContentModeScaleAspectFill;
            iv.frame = avatar.bounds;
            iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [avatar addSubview:iv];
            return;
        }
    }
    UIImageView *def = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"flame.fill"]];
    def.tintColor = SpAccent();
    def.contentMode = UIViewContentModeScaleAspectFit;
    CGFloat side = MAX(20, avatar.bounds.size.width - 20);
    def.frame = CGRectMake((avatar.bounds.size.width - side) / 2, (avatar.bounds.size.height - side) / 2, side, side);
    def.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                          | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [avatar addSubview:def];
}

- (void)applyPanelBackground {
    if (!self.panelBgView) return;
    SparksConfig *cfg = [SparksConfig shared];

    // 底衬:0关 1深色半透明 2玻璃材质
    for (UIView *v in [self.panelBackdropView.subviews copy]) {
        [v removeFromSuperview];
    }
    if (cfg.panelBackdrop == 1) {
        self.panelBackdropView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.4];
        self.panelBackdropView.hidden = NO;
    } else if (cfg.panelBackdrop == 2) {
        self.panelBackdropView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.32];   // 玻璃材质也要垫深色,亮背景下白字才可读
        UIVisualEffectView *glass = SpMakeGlassView();
        UIView *clip = SpGlassWrap(glass, 32);
        clip.userInteractionEnabled = NO;
        [self.panelBackdropView addSubview:clip];
        [NSLayoutConstraint activateConstraints:@[
            [clip.topAnchor constraintEqualToAnchor:self.panelBackdropView.topAnchor],
            [clip.bottomAnchor constraintEqualToAnchor:self.panelBackdropView.bottomAnchor],
            [clip.leadingAnchor constraintEqualToAnchor:self.panelBackdropView.leadingAnchor],
            [clip.trailingAnchor constraintEqualToAnchor:self.panelBackdropView.trailingAnchor],
        ]];
        self.panelBackdropView.hidden = NO;
    } else {
        self.panelBackdropView.hidden = YES;
    }

    UIImage *img = cfg.panelBgPath.length ? [UIImage imageWithContentsOfFile:cfg.panelBgPath] : nil;
    self.panelBgView.image = img;
    self.panelBgView.hidden = !img;
    self.panelDimView.hidden = !img;
}

#pragma mark - 面板骨架

// 拖动头部/页签条移动面板
- (void)panelPanned:(UIPanGestureRecognizer *)g {
    UIView *v = self.panelRoot;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}

// 宽高滑杆回调
- (void)applyPanelSize {
    if (!self.panelRoot) return;
    SparksConfig *cfg = [SparksConfig shared];
    UIView *root = self.panelRoot;
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat w = cfg.panelW ?: MIN(372, screen.size.width - 20);
    CGPoint c = root.center;
    root.frame = CGRectMake(c.x - w / 2, c.y - cfg.panelH / 2, w, cfg.panelH);
    [root layoutIfNeeded];
}

// 页签切换(日志页挂 2s 轮询刷新;离开目标页清掉单独设置状态)
- (void)segChangedTo:(NSInteger)idx {
    self.tab = idx;
    self.animateNextBuild = YES;   // 切页播一次入场
    if (idx != 1) { self.detailKey = nil; self.targetsManaging = NO; }
    [self.logTimer invalidate];
    self.logTimer = nil;
    if (self.tab == 4) {
        self.logTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                         target:[SparksPanel shared]
                                                       selector:@selector(logTimerTick)
                                                       userInfo:nil repeats:YES];
    }
    [self rebuildContent];
}

- (void)logTimerTick {
    if (self.tab == 4 && self.panelRoot.superview && self.logTextView.window) [self refreshLog];
}

- (void)openPanel {
    if (!self.panelWindow) [self createBall];   // 极早期入口点击(设置页🔥)时补建窗口
    [self buildPanelIfNeeded];
    [self.panelWindow.rootViewController.view addSubview:self.panelRoot];
    // 打开面板自动隐藏悬浮球
    self.ballWrapper.hidden = YES;
    [self setBallGifPlaying:NO];
    self.animateNextBuild = YES;   // 开面板播一次入场

    SparksConfig *cfg = [SparksConfig shared];
    CGFloat d = 0.35 / MAX(0.3, cfg.animSpeed);
    UIColor *scrim = [UIColor colorWithWhite:0 alpha:0.2];
    self.panelRoot.alpha = 0;

    CGAffineTransform initT;
    switch (cfg.animPreset) {
        case 1: initT = CGAffineTransformMakeScale(0.7, 0.7); break;
        case 2: initT = CGAffineTransformMakeTranslation(0, 80); break;
        case 3: initT = CGAffineTransformMakeTranslation(-100, 0); break;
        case 4: initT = CGAffineTransformIdentity; break;
        default: initT = CGAffineTransformMakeScale(0.92, 0.92); break;
    }
    self.panelRoot.transform = initT;

    void (^anim)(void) = ^{
        self.panelRoot.alpha = 1;
        self.panelRoot.transform = CGAffineTransformIdentity;
        self.backgroundTapView.backgroundColor = scrim;
    };
    if (cfg.animPreset == 0) {
        [UIView animateWithDuration:d delay:0
             usingSpringWithDamping:0.75 initialSpringVelocity:0.5
                            options:0 animations:anim completion:nil];
    } else {
        [UIView animateWithDuration:d delay:0 options:UIViewAnimationOptionCurveEaseOut
                         animations:anim completion:nil];
    }
    [self rebuildContent];
}

- (void)closePanel {
    [self hideDonate];
    [self.logTimer invalidate];
    self.logTimer = nil;
    [self.panelRoot endEditing:YES];
    SparksConfig *cfg = [SparksConfig shared];
    CGFloat d = 0.2 / MAX(0.3, cfg.animSpeed);
    // 关闭动画与预设镜像(此前恒为缩放淡出,预设换了"合"这边也不变)
    CGAffineTransform endT;
    switch (cfg.animPreset) {
        case 1: endT = CGAffineTransformMakeScale(0.7, 0.7); break;
        case 2: endT = CGAffineTransformMakeTranslation(0, 80); break;
        case 3: endT = CGAffineTransformMakeTranslation(-100, 0); break;
        case 4: endT = CGAffineTransformIdentity; break;      // 淡入淡出:只动透明度
        default: endT = CGAffineTransformMakeScale(0.92, 0.92); break;
    }
    UIView *closing = self.panelRoot;   // 只关闭这一实例:refreshChrome 可能在动画期间已重建新面板
    __weak typeof(self) ws = self;
    [UIView animateWithDuration:d delay:0 options:0 animations:^{
        typeof(self) s = ws;
        if (s) {
            closing.alpha = 0;
            closing.transform = endT;
            s.backgroundTapView.backgroundColor = [UIColor clearColor];
        }
    } completion:^(BOOL finished) {
        typeof(self) s = ws;
        if (!s) return;
        [closing removeFromSuperview];
        if (closing != s.panelRoot) return;   // 新面板已接管,勿移除它/勿提前恢复悬浮球
        s.panelRoot.transform = CGAffineTransformIdentity;
        // 恢复悬浮球
        s.ballWrapper.hidden = NO;
        [s setBallGifPlaying:YES];
        [[SparksConfig shared] save];
    }];
}

- (void)buildPanelIfNeeded {
    if (self.panelRoot) return;
    SparksConfig *cfg = [SparksConfig shared];
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat pw = cfg.panelW ?: MIN(372, screen.size.width - 20);
    CGFloat ph = cfg.panelH ?: MIN(600, screen.size.height - 110);

    UIView *root = [[UIView alloc] initWithFrame:CGRectMake((screen.size.width - pw) / 2,
                                                            (screen.size.height - ph) / 2, pw, ph)];
    root.backgroundColor = [UIColor clearColor];   // v2.13.2 用户点名取消淡底:卡片直浮于视频上
    // 根容器统一圆角+裁切:内容卡片(边距 14pt<32pt 圆角)在底衬圆角外穿直角的根因修复
    root.layer.cornerRadius = 32;
    root.layer.cornerCurve = kCACornerCurveContinuous;
    root.clipsToBounds = YES;

    // 面板底衬(深色/玻璃材质)
    UIView *backdrop = [[UIView alloc] init];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.layer.cornerRadius = 32;
    backdrop.layer.cornerCurve = kCACornerCurveContinuous;
    backdrop.clipsToBounds = YES;
    backdrop.userInteractionEnabled = NO;
    [root addSubview:backdrop];

    // 自定义背景图 + 压暗层(v2.0.0 起缺约束导致不可见,v2.1.3 修复)
    UIImageView *bgv = [[UIImageView alloc] init];
    bgv.translatesAutoresizingMaskIntoConstraints = NO;
    bgv.contentMode = UIViewContentModeScaleAspectFill;
    bgv.clipsToBounds = YES;
    bgv.layer.cornerRadius = 32;
    bgv.layer.cornerCurve = kCACornerCurveContinuous;
    bgv.hidden = YES;
    bgv.userInteractionEnabled = NO;
    [root addSubview:bgv];
    UIView *dim = [[UIView alloc] init];
    dim.translatesAutoresizingMaskIntoConstraints = NO;
    dim.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
    dim.layer.cornerRadius = 32;
    dim.layer.cornerCurve = kCACornerCurveContinuous;
    dim.hidden = YES;
    dim.userInteractionEnabled = NO;
    [root addSubview:dim];

    [NSLayoutConstraint activateConstraints:@[
        [backdrop.topAnchor constraintEqualToAnchor:root.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [backdrop.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [bgv.topAnchor constraintEqualToAnchor:root.topAnchor],
        [bgv.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [bgv.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [bgv.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [dim.topAnchor constraintEqualToAnchor:root.topAnchor],
        [dim.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [dim.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [dim.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
    ]];

    // ===== 头部玻璃卡(资料行:头像 + 昵称/ID 同行 + 签名单行) =====
    SparksGlassCard *header = [[SparksGlassCard alloc] initWithCardTitle:nil];
    [root addSubview:header];
    [header.topAnchor constraintEqualToAnchor:root.topAnchor constant:12].active = YES;
    [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:14].active = YES;
    [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-14].active = YES;

    UIView *surface = header.surface;

    UIView *avatar = [[UIView alloc] init];
    avatar.translatesAutoresizingMaskIntoConstraints = NO;
    avatar.layer.cornerRadius = 20;
    avatar.layer.cornerCurve = kCACornerCurveContinuous;
    avatar.clipsToBounds = YES;
    [surface addSubview:avatar];
    [avatar.leadingAnchor constraintEqualToAnchor:surface.leadingAnchor constant:14].active = YES;
    [avatar.widthAnchor constraintEqualToConstant:40].active = YES;
    [self applyAvatarInto:avatar];

    UILabel *nameL = [[UILabel alloc] init];
    nameL.text = cfg.nickName.length ? cfg.nickName : @"AI 续火花";
    nameL.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    nameL.textColor = [UIColor whiteColor];
    nameL.translatesAutoresizingMaskIntoConstraints = NO;
    [surface addSubview:nameL];
    [nameL.leadingAnchor constraintEqualToAnchor:avatar.trailingAnchor constant:10].active = YES;
    // 文字块相对头像垂直居中(有签名时整体上移半行,不再顶锚贴上)
    [nameL.centerYAnchor constraintEqualToAnchor:avatar.centerYAnchor
                                        constant:(cfg.signature.length ? -8.0 : 0.0)].active = YES;
    [nameL.topAnchor constraintGreaterThanOrEqualToAnchor:surface.topAnchor constant:8].active = YES;

    UIControl *close = [[UIControl alloc] init];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *xmark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"xmark"]];
    xmark.tintColor = SpW(0.85);
    xmark.contentMode = UIViewContentModeScaleAspectFit;
    xmark.userInteractionEnabled = NO;
    xmark.translatesAutoresizingMaskIntoConstraints = NO;
    [close addSubview:xmark];
    [xmark.centerXAnchor constraintEqualToAnchor:close.centerXAnchor].active = YES;
    [xmark.centerYAnchor constraintEqualToAnchor:close.centerYAnchor].active = YES;
    [xmark.widthAnchor constraintEqualToConstant:14].active = YES;
    [xmark.heightAnchor constraintEqualToConstant:14].active = YES;
    [surface addSubview:close];
    [close.trailingAnchor constraintEqualToAnchor:surface.trailingAnchor constant:-12].active = YES;
    [close.centerYAnchor constraintEqualToAnchor:avatar.centerYAnchor].active = YES;
    [close.widthAnchor constraintEqualToConstant:32].active = YES;
    [close.heightAnchor constraintEqualToConstant:32].active = YES;
    [close addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [nameL.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-8].active = YES;

    // v2.19.5:头部也是"所有 tab 共用"的,必须一起换 —— 新风格收起头像块,改标题式头部
    {
        avatar.hidden = YES;
        nameL.hidden = YES;
        UILabel *t = [[UILabel alloc] init];
        t.text = @"续火花";
        t.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        t.textColor = SpArtTextColor();
        t.textAlignment = NSTextAlignmentLeft;
        t.translatesAutoresizingMaskIntoConstraints = NO;
        [surface addSubview:t];
        [t.centerYAnchor constraintEqualToAnchor:surface.centerYAnchor].active = YES;
        [t.leadingAnchor constraintEqualToAnchor:surface.leadingAnchor constant:16].active = YES;
    }

    // 授权专属 ID 徽标已随授权校验一并移除(v2.18.1)
    if (cfg.signature.length) {
        UILabel *sig = [[UILabel alloc] init];
        sig.text = cfg.signature;
        sig.font = [UIFont systemFontOfSize:11];
        sig.textColor = SpW(0.6);
        sig.numberOfLines = 1;
        sig.lineBreakMode = NSLineBreakByTruncatingTail;
        sig.translatesAutoresizingMaskIntoConstraints = NO;
        [surface addSubview:sig];
        [sig.leadingAnchor constraintEqualToAnchor:nameL.leadingAnchor].active = YES;
        [sig.topAnchor constraintEqualToAnchor:nameL.bottomAnchor constant:2].active = YES;
        [sig.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-8].active = YES;
    }
    [avatar.topAnchor constraintEqualToAnchor:surface.topAnchor constant:10].active = YES;
    [avatar.heightAnchor constraintEqualToConstant:40].active = YES;
    [avatar.bottomAnchor constraintEqualToAnchor:surface.bottomAnchor constant:-10].active = YES;

    // 首页快捷编辑:点头像=换头像(直达相册),点昵称区=改昵称/签名(v2.14.4 分开)
    avatar.userInteractionEnabled = YES;
    UITapGestureRecognizer *editTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(avatarEditTapped)];
    [avatar addGestureRecognizer:editTap];
    nameL.userInteractionEnabled = YES;
    UITapGestureRecognizer *editTap2 = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(profileEditTapped)];
    [nameL addGestureRecognizer:editTap2];

    // ===== 页签 dock(悬浮圆片:选中浮起玻璃圆片+主题色图标+底部圆点) =====
    SparksGlassSeg *seg = [[SparksGlassSeg alloc] initWithTitles:@[@"状态", @"目标", @"外观", @"设置", @"日志"]
                                                       selection:^(NSInteger idx) {
        typeof(self) s = [SparksPanel spShared];
        [s segChangedTo:idx];
    }];
    [seg setIndex:self.tab animated:NO];   // 外观重建后保持当前页,避免圆片与内容错位
    seg.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:seg];
    // v2.19.2:dock 位置随风格走 —— 玻璃风格在头部下方(原样),三种新风格挪到面板底部
    BOOL dockBottom = YES;   // v2.22.0:dock 固定在面板底部
    if (dockBottom) {
        [seg.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-14].active = YES;
    } else {
        [seg.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:12].active = YES;
    }
    [seg.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:14].active = YES;
    [seg.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-14].active = YES;
    [seg.heightAnchor constraintEqualToConstant:52].active = YES;

    // ===== 内容滚动区 =====
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.showsVerticalScrollIndicator = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    // v2.14:首卡/末卡与面板边缘的间距=卡间距 12,整体节奏一致
    scroll.contentInset = UIEdgeInsetsMake(12, 0, 12, 0);
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:scroll];
    if (dockBottom) {
        // dock 在底部:内容区从头部下方一直到 dock 上沿
        [scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:12].active = YES;
        [scroll.bottomAnchor constraintEqualToAnchor:seg.topAnchor constant:-12].active = YES;
    } else {
        [scroll.topAnchor constraintEqualToAnchor:seg.bottomAnchor constant:12].active = YES;
        [scroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-14].active = YES;
    }
    [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:14].active = YES;
    [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-14].active = YES;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
    ]];

    // 拖动头部/页签条移动面板
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panelPanned:)];
    [header addGestureRecognizer:pan];
    UIPanGestureRecognizer *panSeg = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panelPanned:)];
    [seg addGestureRecognizer:panSeg];

    self.panelRoot = root;
    self.panelBackdropView = backdrop;
    self.panelBgView = bgv;
    self.panelDimView = dim;
    self.seg = seg;
    self.scroll = scroll;
    self.stack = stack;

    [self applyPanelBackground];
}

#pragma mark - 内容构建(合并刷新,输入中跳过)

- (NSString *)stateSignature {
    SparksConfig *cfg = [SparksConfig shared];
    SparksEngine *eng = [SparksEngine shared];
    NSUInteger done = 0;
    for (NSDictionary *t in cfg.targets) if ([cfg sentToday:SpTargetKeyOf(t)]) done++;
    // 含 tab:切换页面必须重建(去重只挡同页同状态的重复刷新);
    // 含底衬/背景图:切换后行标签与即时视觉保持一致
    return [NSString stringWithFormat:@"tab%ld|%lu|%d|%d|%lu|%d|bd%ld|bg%d",
            (long)self.tab, (unsigned long)cfg.targets.count, cfg.master, eng.running,
            (unsigned long)done, cfg.sendTemplate != nil,
            (long)cfg.panelBackdrop, cfg.panelBgPath.length > 0];
}

- (void)scheduleRebuild {
    if (!self.panelRoot.superview) return;
    if (self.busyButton) return;   // 按钮动画播放中,别把按钮重建掉
    self.lastSig = nil;   // 用户操作一律强制重建:行标签/输入框即时刷新,不被签名去重吞掉
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(rebuildContent) object:nil];
    [self performSelector:@selector(rebuildContent) withObject:nil afterDelay:0.25];
}

// 引擎状态回调专用:签名未变不重建(发热优化,去重只留给非用户路径)
- (void)scheduleRebuildIfChanged {
    if (!self.panelRoot.superview) return;
    if (self.busyButton) return;   // 同上
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(rebuildContent) object:nil];
    [self performSelector:@selector(rebuildContent) withObject:nil afterDelay:0.25];
}

- (void)rebuildContent {
    if (!self.stack) return;
    if (gEditingFields > 0) return;
    NSString *sig = [self stateSignature];
    if (_lastSig && [sig isEqualToString:_lastSig]) return;   // 状态未变不重建
    _lastSig = sig;

    for (UIView *v in [self.stack.arrangedSubviews copy]) {
        [self.stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    self.logTextView = nil;

    switch (self.tab) {
        case 0: [self buildStatusTab]; break;
        case 1: [self buildTargetsTab]; break;
        case 2: [self buildAppearanceTab]; break;
        case 3: [self buildSettingsTab]; break;
        case 4: [self buildLogTab]; break;
        default: break;
    }
    if (self.animateNextBuild) {
        self.animateNextBuild = NO;
        [self spAnimateStackEntries];
    }
}

#pragma mark - 动效

// 动效:切页/开面板时卡片错峰上浮(45ms 一张,避免每次刷新都闪)
- (void)spAnimateStackEntries {
    NSUInteger i = 0;
    for (UIView *v in [self.stack.arrangedSubviews copy]) {
        v.alpha = 0;
        v.transform = CGAffineTransformMakeTranslation(0, 12);
        [UIView animateWithDuration:0.34 delay:0.045 * i
             usingSpringWithDamping:0.88 initialSpringVelocity:0.25
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            v.alpha = 1;
            v.transform = CGAffineTransformIdentity;
        } completion:nil];
        i++;
    }
}

#pragma mark - 状态页

#pragma mark - 控制台风格首屏(v2.19.0)

- (void)spBuildConsoleHeader {
    SparksConfig *cfg = [SparksConfig shared];
    SparksEngine *eng = [SparksEngine shared];

    NSUInteger done = 0;
    for (NSDictionary *t in cfg.targets) if ([cfg sentToday:SpTargetKeyOf(t)]) done++;

    SparksGlassCard *head = [[SparksGlassCard alloc] initWithCardTitle:nil];
    UIView *s = head.surface;

    SparksRingGauge *gauge = [[SparksRingGauge alloc] initWithFrame:CGRectMake(0, 0, 96, 96)];
    gauge.translatesAutoresizingMaskIntoConstraints = NO;
    [s addSubview:gauge];
    [NSLayoutConstraint activateConstraints:@[
        [gauge.leadingAnchor constraintEqualToAnchor:s.leadingAnchor constant:16],
        [gauge.topAnchor constraintEqualToAnchor:s.topAnchor constant:16],
        [gauge.bottomAnchor constraintEqualToAnchor:s.bottomAnchor constant:-16],
        [gauge.widthAnchor constraintEqualToConstant:96],
        [gauge.heightAnchor constraintEqualToConstant:96],
    ]];
    [gauge setDone:done total:cfg.targets.count];

    UILabel *next = [[UILabel alloc] init];
    next.text = [NSString stringWithFormat:@"下一轮 %@", SpFormatHM(cfg.todayEffectiveTime ?: cfg.dailyTime)];
    next.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    next.textColor = SpArtTextColor();
    next.translatesAutoresizingMaskIntoConstraints = NO;
    [s addSubview:next];

    UILabel *sub = SpMakeSubLabel([NSString stringWithFormat:@"间隔 %.2fs · %lu 个目标%@",
        cfg.interval, (unsigned long)cfg.targets.count, eng.running ? @" · 执行中" : @" · 待命"]);
    [s addSubview:sub];

    [NSLayoutConstraint activateConstraints:@[
        [next.leadingAnchor constraintEqualToAnchor:gauge.trailingAnchor constant:16],
        [next.topAnchor constraintEqualToAnchor:gauge.topAnchor constant:14],
        [next.trailingAnchor constraintLessThanOrEqualToAnchor:s.trailingAnchor constant:-16],
        [sub.leadingAnchor constraintEqualToAnchor:next.leadingAnchor],
        [sub.topAnchor constraintEqualToAnchor:next.bottomAnchor constant:4],
        [sub.trailingAnchor constraintLessThanOrEqualToAnchor:s.trailingAnchor constant:-16],
    ]];
    [self.stack addArrangedSubview:head];
}

#pragma mark - 控制台状态页(整体重排)

- (void)spBuildConsoleTab {
    [self spBuildConsoleHeader];    // 环形进度 + 下一轮 + 间隔
    [self spBuildConsoleMetrics];   // 2×2 指标砖
    [self spBuildConsoleButton];    // 主按钮
    [self spBuildConsoleOps];       // 紧凑操作行
}

- (UIStackView *)spConsoleRow:(NSArray<UIView *> *)tiles {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:tiles];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 12;
    return row;
}

- (void)spBuildConsoleMetrics {
    SparksConfig *cfg = [SparksConfig shared];
    NSUInteger total = cfg.targets.count, done = 0;
    for (NSDictionary *t in cfg.targets) if ([cfg sentToday:SpTargetKeyOf(t)]) done++;

    SparksGlassCard *card = [[SparksGlassCard alloc] initWithCardTitle:nil];
    UIView *s = card.surface;

    UIView *(^tile)(NSString *, NSString *, UIColor *) = ^UIView *(NSString *title, NSString *value, UIColor *vc) {
        UIView *box = [[UIView alloc] init];
        box.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *t = [[UILabel alloc] init];
        t.text = title;
        t.font = [UIFont systemFontOfSize:11];
        t.textColor = SpW(0.55);
        t.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *v = [[UILabel alloc] init];
        v.text = value;
        v.font = SpRounded(20, 0.6);
        v.textColor = vc;
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [box addSubview:t];
        [box addSubview:v];
        [NSLayoutConstraint activateConstraints:@[
            [t.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
            [t.topAnchor constraintEqualToAnchor:box.topAnchor],
            [v.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
            [v.topAnchor constraintEqualToAnchor:t.bottomAnchor constant:4],
            [v.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
        ]];
        return box;
    };

    UIColor *doneColor = (total && done >= total) ? [UIColor systemGreenColor] : [UIColor whiteColor];
    UIStackView *r1 = [self spConsoleRow:@[
        tile(@"今日已发", [NSString stringWithFormat:@"%lu/%lu", (unsigned long)done, (unsigned long)total], doneColor),
        tile(@"待发", [NSString stringWithFormat:@"%lu", (unsigned long)(total - done)], SpAccent()),
    ]];
    UIStackView *r2 = [self spConsoleRow:@[
        tile(@"下一轮", SpFormatHM(cfg.todayEffectiveTime ?: cfg.dailyTime), [UIColor whiteColor]),
        tile(@"发送间隔", [NSString stringWithFormat:@"%.2fs", cfg.interval], [UIColor whiteColor]),
    ]];
    r1.translatesAutoresizingMaskIntoConstraints = NO;
    r2.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *grid = [[UIStackView alloc] initWithArrangedSubviews:@[r1, r2]];
    grid.axis = UILayoutConstraintAxisVertical;
    grid.spacing = 14;
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    [s addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.leadingAnchor constraintEqualToAnchor:s.leadingAnchor constant:16],
        [grid.trailingAnchor constraintEqualToAnchor:s.trailingAnchor constant:-16],
        [grid.topAnchor constraintEqualToAnchor:s.topAnchor constant:14],
        [grid.bottomAnchor constraintEqualToAnchor:s.bottomAnchor constant:-14],
    ]];
    [self.stack addArrangedSubview:card];
}

- (void)spBuildConsoleButton {
    __weak typeof(self) ws = self;
    SparksCapsuleButton *go = [[SparksCapsuleButton alloc] initWithTitle:@"立即续火花" icon:@"flame.fill" primary:YES];
    // 容器负责撑满一行;按钮自己用宽度约束,收缩时居中变圆
    UIView *wrap = [[UIView alloc] init];
    wrap.translatesAutoresizingMaskIntoConstraints = NO;
    [wrap addSubview:go];
    NSLayoutConstraint *stretchC = [go.widthAnchor constraintEqualToAnchor:wrap.widthAnchor];
    NSLayoutConstraint *squareC = [go.widthAnchor constraintEqualToConstant:48];
    squareC.active = NO;   // 常态满宽,收缩时才启用
    go.stretchWidth = stretchC;
    go.collapseWidth = squareC;
    [NSLayoutConstraint activateConstraints:@[
        [go.topAnchor constraintEqualToAnchor:wrap.topAnchor],
        [go.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor],
        [go.centerXAnchor constraintEqualToAnchor:wrap.centerXAnchor],
        stretchC,
    ]];
    __weak SparksCapsuleButton *weakGo = go;
    go.onTap = ^{
        typeof(self) s2 = ws;
        if (!s2) return;
        [weakGo startLoading];            // ① 文字淡出 ② 收成圆 ③ 旋转圆环
        s2.busyButton = weakGo;           // 动画期间冻结重建,否则按钮会被立刻重建掉
        [[SparksConfig shared] save];
        [[SparksEngine shared] runDailyNow:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            typeof(self) s3 = ws;
            if (!s3) return;
            s3.busyButton = nil;
            [s3 scheduleRebuild];
        });
    };
    [self.stack addArrangedSubview:wrap];
}

- (void)spBuildConsoleOps {
    SparksConfig *cfg = [SparksConfig shared];
    __weak typeof(self) ws = self;
    SparksGlassCard *ops = [[SparksGlassCard alloc] initWithCardTitle:nil];
    [ops addRow:[SparksInfoRow switchWithTitle:@"总开关" on:cfg.master onChange:^(BOOL on) {
        SparksConfig *c = [SparksConfig shared];
        c.master = on;
        [c save];
        SparksLog(@"总开关:%@", on ? @"开" : @"关");
        typeof(self) s = ws;
        if (s) dispatch_async(dispatch_get_main_queue(), ^{ [s scheduleRebuild]; });
    }]];
    [ops addRow:SpRowSeparator()];
    [ops addRow:[SparksInfoRow actionWithTitle:@"目标"
                                        value:[NSString stringWithFormat:@"%lu 个", (unsigned long)cfg.targets.count]
                                        onTap:^{
        typeof(self) s = ws;
        if (s) [s segChangedTo:1];
    }]];
    [ops addRow:SpRowSeparator()];
    [ops addRow:[SparksInfoRow actionWithTitle:@"定时"
                                        value:SpFormatHM(cfg.todayEffectiveTime ?: cfg.dailyTime)
                                        onTap:^{
        typeof(self) s = ws;
        if (s) [s segChangedTo:3];
    }]];
    [ops addRow:SpRowSeparator()];
    [ops addRow:[SparksInfoRow infoWithTitle:@"发送方式" value:@"免跳页直发"]];
    [self.stack addArrangedSubview:ops];
}

#pragma mark - 目标卡片流(v2.19.0)

#pragma mark - 状态页

- (void)buildStatusTab {
    [self spBuildConsoleTab];
}


#pragma mark - 目标页

// 目标卡片:首字母头像 + 昵称 + 群/单聊 + 已发/待发
- (UIView *)spFeedCardForTarget:(NSDictionary *)t {
    SparksConfig *cfg = [SparksConfig shared];
    NSString *key = SpTargetKeyOf(t);
    if (!key.length) return nil;
    BOOL sent = [cfg sentToday:key];
    BOOL group = [t[@"type"] isKindOfClass:[NSString class]] && [t[@"type"] isEqualToString:@"group"];
    NSString *name = [t[@"name"] isKindOfClass:[NSString class]] ? t[@"name"] : key;
    if (!name.length) name = key;

    SparksGlassCard *card = [[SparksGlassCard alloc] initWithCardTitle:nil];
    UIView *s = card.surface;

    static NSArray<UIColor *> *palette;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        palette = @[[UIColor systemOrangeColor], [UIColor systemBlueColor],
                    [UIColor systemGreenColor], [UIColor systemPurpleColor],
                    [UIColor systemPinkColor], [UIColor systemTealColor]];
    });
    UIColor *tint = palette[(NSUInteger)(key.hash % palette.count)];

    UIView *avatar = [[UIView alloc] init];
    avatar.translatesAutoresizingMaskIntoConstraints = NO;
    avatar.backgroundColor = [tint colorWithAlphaComponent:0.22];
    avatar.layer.cornerRadius = 22;
    avatar.layer.cornerCurve = kCACornerCurveContinuous;
    [s addSubview:avatar];
    UILabel *initial = [[UILabel alloc] init];
    initial.text = [name substringToIndex:1];
    initial.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    initial.textColor = tint;
    initial.textAlignment = NSTextAlignmentCenter;
    initial.translatesAutoresizingMaskIntoConstraints = NO;
    [avatar addSubview:initial];

    UILabel *title = [[UILabel alloc] init];
    title.text = name;
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    title.textColor = [UIColor whiteColor];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [s addSubview:title];

    UILabel *sub = SpMakeSubLabel(group ? @"群聊" : @"单聊");
    [s addSubview:sub];

    UIView *chip = [[UIView alloc] init];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    chip.layer.cornerRadius = 11;
    chip.layer.cornerCurve = kCACornerCurveContinuous;
    chip.backgroundColor = sent ? [[UIColor systemGreenColor] colorWithAlphaComponent:0.18]
                                : [SpAccent() colorWithAlphaComponent:0.18];
    [s addSubview:chip];
    UILabel *chipLabel = [[UILabel alloc] init];
    chipLabel.text = sent ? @"已发" : @"待发";
    chipLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    chipLabel.textColor = sent ? [UIColor systemGreenColor] : SpAccent();
    chipLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [chip addSubview:chipLabel];

    [NSLayoutConstraint activateConstraints:@[
        [avatar.leadingAnchor constraintEqualToAnchor:s.leadingAnchor constant:16],
        [avatar.centerYAnchor constraintEqualToAnchor:s.centerYAnchor],
        [avatar.widthAnchor constraintEqualToConstant:44],
        [avatar.heightAnchor constraintEqualToConstant:44],
        [avatar.topAnchor constraintEqualToAnchor:s.topAnchor constant:14],
        [avatar.bottomAnchor constraintEqualToAnchor:s.bottomAnchor constant:-14],
        [initial.centerXAnchor constraintEqualToAnchor:avatar.centerXAnchor],
        [initial.centerYAnchor constraintEqualToAnchor:avatar.centerYAnchor],
        [title.leadingAnchor constraintEqualToAnchor:avatar.trailingAnchor constant:12],
        [title.topAnchor constraintEqualToAnchor:avatar.topAnchor constant:3],
        [sub.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
        [chip.trailingAnchor constraintEqualToAnchor:s.trailingAnchor constant:-16],
        [chip.centerYAnchor constraintEqualToAnchor:s.centerYAnchor],
        [chip.widthAnchor constraintEqualToConstant:52],
        [chip.heightAnchor constraintEqualToConstant:22],
        [chipLabel.centerXAnchor constraintEqualToAnchor:chip.centerXAnchor],
        [chipLabel.centerYAnchor constraintEqualToAnchor:chip.centerYAnchor],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:chip.leadingAnchor constant:-10],
    ]];

    // 点卡片进入该目标的单独设置
    objc_setAssociatedObject(card, "spKey", key, OBJC_ASSOCIATION_COPY_NONATOMIC);
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(spTargetCardTapped:)];
    [card addGestureRecognizer:tap];
    card.userInteractionEnabled = YES;
    return card;
}

- (void)spTargetCardTapped:(UITapGestureRecognizer *)g {
    NSString *key = objc_getAssociatedObject(g.view, "spKey");
    if (!key.length) return;
    self.detailKey = key;
    [self scheduleRebuild];
}

- (void)buildTargetsTab {
    SparksConfig *cfg = [SparksConfig shared];

    // 目标单独设置页(v2.13):detailKey 非空时整页切到该目标的单独设置
    if (self.detailKey.length) {
        [self buildTargetDetail];
        return;
    }

    // 目标页:默认卡片流(每人一张卡);点「管理目标」才切到原来的可左滑删除的行列表。
    // 两者互斥渲染 —— 之前两边都渲染,同一个目标会同时以卡片和行出现,看起来"有两个目标"。
    if (cfg.targets.count && !self.targetsManaging) {
        for (NSDictionary *t in [cfg.targets copy]) {
            UIView *feedCard = [self spFeedCardForTarget:t];
            if (feedCard) [self.stack addArrangedSubview:feedCard];
        }
        SparksGlassCard *manage = [[SparksGlassCard alloc] initWithCardTitle:nil];
        __weak typeof(self) wsm = self;
        [manage addRow:[SparksInfoRow actionWithTitle:@"管理目标(删除 / 调整)"
                                               value:[NSString stringWithFormat:@"%lu 个 ›", (unsigned long)cfg.targets.count]
                                               onTap:^{
            typeof(self) s2 = wsm;
            if (!s2) return;
            s2.targetsManaging = YES;
            [s2 scheduleRebuild];
        }]];
        [self.stack addArrangedSubview:manage];
        return;
    }
    if (self.targetsManaging && cfg.targets.count) {
        SparksGlassCard *back = [[SparksGlassCard alloc] initWithCardTitle:nil];
        __weak typeof(self) wsb = self;
        [back addRow:[SparksInfoRow actionWithTitle:@"← 返回目标卡片" value:@"" onTap:^{
            typeof(self) s3 = wsb;
            if (!s3) return;
            s3.targetsManaging = NO;
            [s3 scheduleRebuild];
        }]];
        [self.stack addArrangedSubview:back];
    }

    SparksGlassCard *card = [[SparksGlassCard alloc]
        initWithCardTitle:[NSString stringWithFormat:@"目标 · %lu 个", (unsigned long)cfg.targets.count]];

    if (!cfg.targets.count) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"还没有目标\n在抖音里打开好友/群聊聊天页后,会出现在下方\"最近聊天\"";
        empty.numberOfLines = 0;
        empty.textAlignment = NSTextAlignmentCenter;
        empty.font = [UIFont systemFontOfSize:12];
        empty.textColor = SpW(0.75);
        empty.translatesAutoresizingMaskIntoConstraints = NO;
        [card addRow:empty];
    }

    for (NSDictionary *t in [cfg.targets copy]) {
        NSString *key = SpTargetKeyOf(t);
        BOOL isGroup = SpTargetIsGroupOf(t);
        NSString *name = SpTargetDisplayName(t);
        BOOL sent = [cfg sentToday:key];

        // 左滑揭示删除(v2.14.3:滑出红色删除按钮,再点删除;点行/右滑收回)
        UIView *row = [[UIView alloc] init];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.userInteractionEnabled = YES;
        row.clipsToBounds = YES;   // 揭示按钮从右缘外滑入,不外溢
        [row.heightAnchor constraintEqualToConstant:54].active = YES;

        UIView *content = [[UIView alloc] init];
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:content];
        [NSLayoutConstraint activateConstraints:@[
            [content.topAnchor constraintEqualToAnchor:row.topAnchor],
            [content.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
            [content.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [content.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        ]];

        UILabel *nameL = [[UILabel alloc] init];
        nameL.attributedText = SpDotTitle([NSString stringWithFormat:@"%@ %@", name, isGroup ? @"·群" : @""],
                                          sent ? [UIColor systemGreenColor] : SpW(0.3));
        nameL.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:nameL];
        [nameL.leadingAnchor constraintEqualToAnchor:content.leadingAnchor].active = YES;
        [nameL.topAnchor constraintEqualToAnchor:content.topAnchor constant:8].active = YES;

        UILabel *uidL = SpMakeSubLabel([NSString stringWithFormat:@"%@ · %@ · 点击进入单独设置,左滑删除", key, isGroup ? @"群聊" : @"单聊"]);
        [content addSubview:uidL];
        [uidL.leadingAnchor constraintEqualToAnchor:content.leadingAnchor].active = YES;
        [uidL.topAnchor constraintEqualToAnchor:nameL.bottomAnchor constant:2].active = YES;

        UIControl *delBtn = [[UIControl alloc] init];
        delBtn.backgroundColor = [UIColor colorWithRed:0.78 green:0.19 blue:0.17 alpha:1.0];
        delBtn.layer.cornerRadius = 12;
        delBtn.layer.cornerCurve = kCACornerCurveContinuous;
        delBtn.translatesAutoresizingMaskIntoConstraints = NO;
        UIImageView *dic = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"trash.fill"]];
        dic.tintColor = [UIColor whiteColor];
        dic.contentMode = UIViewContentModeScaleAspectFit;
        dic.userInteractionEnabled = NO;
        dic.translatesAutoresizingMaskIntoConstraints = NO;
        [delBtn addSubview:dic];
        UILabel *dl = [[UILabel alloc] init];
        dl.text = @"删除";
        dl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        dl.textColor = [UIColor whiteColor];
        dl.userInteractionEnabled = NO;
        dl.translatesAutoresizingMaskIntoConstraints = NO;
        [delBtn addSubview:dl];
        [dic.leadingAnchor constraintEqualToAnchor:delBtn.leadingAnchor constant:10].active = YES;
        [dic.centerYAnchor constraintEqualToAnchor:delBtn.centerYAnchor].active = YES;
        [dic.widthAnchor constraintEqualToConstant:15].active = YES;
        [dic.heightAnchor constraintEqualToConstant:15].active = YES;
        [dl.leadingAnchor constraintEqualToAnchor:dic.trailingAnchor constant:4].active = YES;
        [dl.centerYAnchor constraintEqualToAnchor:delBtn.centerYAnchor].active = YES;
        [row addSubview:delBtn];
        [delBtn.topAnchor constraintEqualToAnchor:row.topAnchor constant:5].active = YES;
        [delBtn.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-5].active = YES;
        [delBtn.trailingAnchor constraintEqualToAnchor:row.trailingAnchor].active = YES;
        [delBtn.widthAnchor constraintEqualToConstant:76].active = YES;
        delBtn.transform = CGAffineTransformMakeTranslation(80, 0);   // 藏在右缘外

        NSDictionary *captured = [t copy];
        objc_setAssociatedObject(row, "content", content, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(row, "delbtn", delBtn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(row, "target", captured, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(delBtn, "target", captured, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapTargetFromGesture:)];
        [row addGestureRecognizer:tap];
        UISwipeGestureRecognizer *swl = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeDeleteTargetFromGesture:)];
        swl.direction = UISwipeGestureRecognizerDirectionLeft;
        [row addGestureRecognizer:swl];
        UISwipeGestureRecognizer *swr = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeCloseTargetFromGesture:)];
        swr.direction = UISwipeGestureRecognizerDirectionRight;
        [row addGestureRecognizer:swr];
        [delBtn addTarget:self action:@selector(targetDeleteConfirmFromSender:) forControlEvents:UIControlEventTouchUpInside];

        [card addRow:row];
        [card addRow:SpRowSeparator()];
    }

    [self.stack addArrangedSubview:card];

    // 最近聊天卡
    SparksGlassCard *recent = [[SparksGlassCard alloc] initWithCardTitle:@"最近聊天"];
    BOOL any = NO;
    for (NSDictionary *rc in [cfg.recents copy]) {
        NSString *key = rc[@"key"];
        if (![key isKindOfClass:[NSString class]] || !key.length) key = rc[@"uid"];
        if (![key isKindOfClass:[NSString class]] || !key.length) continue;
        BOOL isGroup = [rc[@"type"] isEqualToString:@"group"];
        BOOL already = NO;
        for (NSDictionary *t in cfg.targets) {
            if ([SpTargetKeyOf(t) isEqualToString:key]) { already = YES; break; }
        }
        if (already) continue;
        any = YES;

        UIView *row = [[UIView alloc] init];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.userInteractionEnabled = YES;
        [row.heightAnchor constraintEqualToConstant:48].active = YES;

        UIImageView *plus = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"plus.circle.fill"]];
        plus.tintColor = isGroup ? [UIColor systemBlueColor] : SpAccent();
        plus.contentMode = UIViewContentModeScaleAspectFit;
        plus.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:plus];
        [plus.leadingAnchor constraintEqualToAnchor:row.leadingAnchor].active = YES;
        [plus.centerYAnchor constraintEqualToAnchor:row.centerYAnchor].active = YES;
        [plus.widthAnchor constraintEqualToConstant:20].active = YES;
        [plus.heightAnchor constraintEqualToConstant:20].active = YES;

        UIStackView *mid = [[UIStackView alloc] init];
        mid.axis = UILayoutConstraintAxisVertical;
        mid.spacing = 2;
        mid.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:mid];
        [mid addArrangedSubview:SpMakeTitleLabel([NSString stringWithFormat:@"%@ %@",
                                                  rc[@"name"] ?: key, isGroup ? @"· 群聊" : @""], 14)];
        [mid addArrangedSubview:SpMakeSubLabel(key)];
        [mid.leadingAnchor constraintEqualToAnchor:plus.trailingAnchor constant:10].active = YES;
        [mid.centerYAnchor constraintEqualToAnchor:row.centerYAnchor].active = YES;

        NSDictionary *captured = [@{@"key": key,
                                    @"type": isGroup ? @"group" : @"single",
                                    @"name": rc[@"name"] ?: key,
                                    @"secUid": rc[@"secUid"] ?: @""} copy];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(addTargetFromGesture:)];
        [row addGestureRecognizer:tap];
        objc_setAssociatedObject(row, "target", captured, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        [recent addRow:row];
        [recent addRow:SpRowSeparator()];
    }
    if (!any) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"打开过的好友/群聊天页会出现在这里";
        empty.textAlignment = NSTextAlignmentCenter;
        empty.font = [UIFont systemFontOfSize:12];
        empty.textColor = SpW(0.75);
        empty.translatesAutoresizingMaskIntoConstraints = NO;
        [recent addRow:empty];
    }
    [self.stack addArrangedSubview:recent];
}

#pragma mark - 目标单独设置(v2.13)

// 语音包语言码 -> 显示名
static NSString *SpVoiceName(NSString *code) {
    if (![code isKindOfClass:[NSString class]]) return @"未设置";
    if ([code isEqualToString:@"zh-CN"]) return @"普通话";
    if ([code isEqualToString:@"zh-HK"]) return @"粤语";
    if ([code isEqualToString:@"zh-TW"]) return @"台湾腔";
    return @"未设置";
}

- (NSDictionary *)targetForDetailKey {
    if (!self.detailKey.length) return nil;
    for (NSDictionary *t in [SparksConfig shared].targets) {
        if ([SpTargetKeyOf(t) isEqualToString:self.detailKey]) return t;
    }
    return nil;
}

// 改当前详情目标的一个字段并刷新(value=nil 删除该字段恢复默认)
- (void)setDetailField:(NSString *)field value:(id)value {
    NSString *k = self.detailKey;
    if (!k.length) return;
    [[SparksConfig shared] updateTarget:k set:^(NSMutableDictionary *t) {
        if (value) t[field] = value;
        else [t removeObjectForKey:field];
    }];
    [self scheduleRebuild];
}

- (void)editDetailField:(NSString *)title field:(NSString *)field current:(NSString *)cur {
    __weak typeof(self) ws = self;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = cur ?: @"";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        typeof(self) s = ws;
        if (!s) return;
        NSString *v = ac.textFields.firstObject.text ?: @"";
        [s setDetailField:field value:v.length ? v : nil];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *top = [self topVC];
    if (top) [top presentViewController:ac animated:YES completion:nil];
}

// 选项表单(title + 选项 -> 存值),空 extra 走"清除"
- (void)detailSheet:(NSString *)title options:(NSArray<NSDictionary *> *)opts {
    __weak typeof(self) ws = self;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *o in opts) {
        [ac addAction:[UIAlertAction actionWithTitle:o[@"t"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            typeof(self) s = ws;
            if (!s) return;
            id v = o[@"v"];
            [s setDetailField:o[@"f"] value:(v == [NSNull null]) ? nil : v];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *top = [self topVC];
    if (top) {
        ac.popoverPresentationController.sourceView = top.view;
        [top presentViewController:ac animated:YES completion:nil];
    }
}

- (void)buildTargetDetail {
    SparksConfig *cfg = [SparksConfig shared];
    NSDictionary *t = [self targetForDetailKey];
    if (!t) {   // 目标已被删,退回列表
        self.detailKey = nil;
        [self buildTargetsTab];
        return;
    }
    NSString *key = SpTargetKeyOf(t);
    BOOL isGroup = SpTargetIsGroupOf(t);
    BOOL sent = [cfg sentToday:key];
    NSString *remark = [t[@"remark"] isKindOfClass:[NSString class]] ? t[@"remark"] : nil;
    NSString *tprompt = [t[@"tprompt"] isKindOfClass:[NSString class]] ? t[@"tprompt"] : nil;
    NSString *ttext = [t[@"ttext"] isKindOfClass:[NSString class]] ? t[@"ttext"] : nil;
    NSString *imgPath = [t[@"imgPath"] isKindOfClass:[NSString class]] ? t[@"imgPath"] : nil;
    NSInteger mode = [t[@"mode"] integerValue];
    NSInteger dcount = [t[@"dcount"] integerValue];
    if (dcount < 1) dcount = 1;
    NSString *name = SpTargetDisplayName(t);
    __weak typeof(self) ws = self;

    // 返回列表
    SparksGlassCard *nav = [[SparksGlassCard alloc] initWithCardTitle:nil];
    [nav addRow:[SparksInfoRow actionWithTitle:@"返回目标列表" value:@"←" onTap:^{
        typeof(self) s = ws;
        if (!s) return;
        s.detailKey = nil;
        [s scheduleRebuild];
    }]];
    [self.stack addArrangedSubview:nav];

    // 头部:备注名 + key/模式/今日状态
    SparksGlassCard *head = [[SparksGlassCard alloc] initWithCardTitle:nil];
    [head addRow:[SparksInfoRow infoWithTitle:[NSString stringWithFormat:@"%@ %@", name, isGroup ? @"· 群聊" : @""]
                           value:[NSString stringWithFormat:@"%@ · %@ · %@", key,
                                  (mode == 1) ? @"独立文案" : @"AI文案",
                                  sent ? @"今天已发" : @"今天未发"]]];
    [self.stack addArrangedSubview:head];

    // 单独设置
    SparksGlassCard *set = [[SparksGlassCard alloc] initWithCardTitle:@"单独设置"];
    [set addRow:[SparksInfoRow actionWithTitle:@"备注名称" value:remark.length ? remark : @"未设置" onTap:^{
        typeof(self) s = ws; if (!s) return;
        [s editDetailField:@"备注名称" field:@"remark" current:remark];
    }]];
    [set addRow:SpRowSeparator()];
    [set addRow:[SparksInfoRow actionWithTitle:@"续火花模式"
                                          value:(mode == 1) ? (ttext.length ? @"独立文案" : @"独立文案(⚠️未设文案,实际走AI)") : @"AI生成"
                                           onTap:^{
        typeof(self) s = ws; if (!s) return;
        [s detailSheet:@"续火花模式" options:@[
            @{@"t": @"AI生成(默认)", @"f": @"mode", @"v": @0},
            @{@"t": @"独立文案(固定文本,不走AI)", @"f": @"mode", @"v": @1},
        ]];
    }]];
    [set addRow:SpRowSeparator()];
    [set addRow:[SparksInfoRow actionWithTitle:@"AI生成要求" value:tprompt.length ? tprompt : @"未设置" onTap:^{
        typeof(self) s = ws; if (!s) return;
        [s editDetailField:@"AI生成要求(拼进该目标的生成要求)" field:@"tprompt" current:tprompt];
    }]];
    [set addRow:SpRowSeparator()];
    [set addRow:[SparksInfoRow actionWithTitle:@"每日发送条数" value:[NSString stringWithFormat:@"%ld 条", (long)dcount] onTap:^{
        typeof(self) s = ws; if (!s) return;
        [s detailSheet:@"每日发送条数" options:@[
            @{@"t": @"1 条", @"f": @"dcount", @"v": @1},
            @{@"t": @"2 条", @"f": @"dcount", @"v": @2},
            @{@"t": @"3 条", @"f": @"dcount", @"v": @3},
        ]];
    }]];
    [set addRow:SpRowSeparator()];
    [set addRow:[SparksInfoRow actionWithTitle:@"独立文案" value:ttext.length ? @"已设置" : @"未设置(AI失败回退)" onTap:^{
        typeof(self) s = ws; if (!s) return;
        [s editDetailField:@"独立文案(模式选独立文案时直接发它;AI失败也回退它)" field:@"ttext" current:ttext];
    }]];
    [set addRow:SpRowSeparator()];
    [set addRow:[SparksInfoRow actionWithTitle:@"语音包" value:SpVoiceName(t[@"voice"]) onTap:^{
        typeof(self) s = ws; if (!s) return;
        [s detailSheet:@"语音包(需已校准语音)" options:@[
            @{@"t": @"未设置", @"f": @"voice", @"v": [NSNull null]},
            @{@"t": @"普通话", @"f": @"voice", @"v": @"zh-CN"},
            @{@"t": @"粤语", @"f": @"voice", @"v": @"zh-HK"},
            @{@"t": @"台湾腔", @"f": @"voice", @"v": @"zh-TW"},
        ]];
    }]];
    [set addRow:SpRowSeparator()];
    [set addRow:[SparksInfoRow switchWithTitle:@"发送图片(开=该目标必发图)" on:[t[@"imgOn"] boolValue] onChange:^(BOOL on) {
        typeof(self) s = ws; if (!s) return;
        [s setDetailField:@"imgOn" value:@(on)];
    }]];
    [set addRow:SpRowSeparator()];
    [set addRow:[SparksInfoRow actionWithTitle:@"选择图片"
                                          value:imgPath.length ? [imgPath lastPathComponent] : @"未选(随机)" onTap:^{
        typeof(self) s = ws;
        if (!s) return;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"选择图片" message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        [ac addAction:[UIAlertAction actionWithTitle:@"相册选图" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            typeof(self) s2 = ws;
            if (!s2) return;
            [s2 pickImageToFilePrefix:[NSString stringWithFormat:@"sparks_timg_%@", key] completion:^(NSString *path) {
                typeof(self) s3 = ws;
                if (!s3) return;
                [s3 setDetailField:@"imgPath" value:path];
            }];
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"清除指定图(回媒体库随机)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            typeof(self) s2 = ws;
            if (!s2) return;
            [s2 setDetailField:@"imgPath" value:nil];
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *top = [s topVC];
        if (top) {
            ac.popoverPresentationController.sourceView = top.view;
            [top presentViewController:ac animated:YES completion:nil];
        }
    }]];
    [set addRow:SpRowSeparator()];
    [set addRow:[SparksInfoRow switchWithTitle:@"锁定这张图(关=与媒体库随机)" on:[t[@"imgLock"] boolValue] onChange:^(BOOL on) {
        typeof(self) s = ws; if (!s) return;
        [s setDetailField:@"imgLock" value:@(on)];
    }]];
    [self.stack addArrangedSubview:set];

    // 当前将发送汇总(含未校准警示)+ 立即单发快捷入口
    SparksGlassCard *sum = [[SparksGlassCard alloc] initWithCardTitle:@"当前将发送"];
    NSMutableString *sumSub = [NSMutableString stringWithString:
        (mode == 1) ? @"直接发独立文案" : (ttext.length ? @"AI 失败回退独立文案" : @"AI 失败回退全局兜底")];
    NSString *voice = [t[@"voice"] isKindOfClass:[NSString class]] ? t[@"voice"] : nil;
    if (voice.length && !cfg.audioTpl) [sumSub appendString:@" · ⚠️语音未校准,会发文本"];
    if ([t[@"imgOn"] boolValue] && !cfg.mediaTpl) [sumSub appendString:@" · ⚠️图片未校准,会发文本"];
    [sum addRow:[SparksInfoRow infoWithTitle:[NSString stringWithFormat:@"每天 %ld 条 · %@", (long)dcount,
                                                             (mode == 1) ? @"独立文案" : @"AI生成"]
                           value:sumSub]];
    [sum addRow:SpRowSeparator()];
    NSDictionary *tCap = [t copy];
    [sum addRow:[SparksInfoRow actionWithTitle:@"立即续火花一次" value:sent ? @"今日已发过" : @"▶ 手动" onTap:^{
        typeof(self) s = ws;
        if (!s) return;
        if ([[SparksConfig shared] sentToday:key]) {
            SparksLog(@"%@ 今日已发过,跳过手动单发", name);
            [s showToast:@"今日已发过"];
            return;
        }
        SparksLog(@"详情页手动单发:%@[%@]", name, isGroup ? @"群" : @"单");
        [s runSingleTarget:tCap];
    }]];
    [self.stack addArrangedSubview:sum];
}

#pragma mark - 外观页

- (void)buildAppearanceTab {
    SparksConfig *cfg = [SparksConfig shared];
    __weak typeof(self) ws = self;
    CGRect screen = [UIScreen mainScreen].bounds;

    // 材质卡(作用于面板底衬玻璃:卡片在设置风格下恒为实色)
    SparksGlassCard *material = [[SparksGlassCard alloc] initWithCardTitle:@"材质(面板底)"];
    NSArray<NSString *> *mats = SpMaterialNames();
    for (NSInteger i = 0; i < mats.count; i++) {
        [material addRow:[SparksInfoRow actionWithTitle:mats[i]
                                                  value:(cfg.materialMode == i) ? @"✓ 使用中" : @""
                                                  onTap:^{
            typeof(self) s = ws;
            if (!s) return;
            SparksConfig *c = [SparksConfig shared];
            c.materialMode = i;
            // 实色化重设计后材质作用于底衬玻璃:底衬非玻璃时联动切过去,保证切换可见
            if (c.panelBackdrop != 2) {
                c.panelBackdrop = 2;
                SparksLog(@"底衬已联动为玻璃材质");
            }
            [c save];
            SparksLog(@"材质切换:%@", mats[i]);
            [s refreshChrome];
        }]];
        if (i < mats.count - 1) [material addRow:SpRowSeparator()];
    }
    [self.stack addArrangedSubview:material];

    // 主题色卡
    SparksGlassCard *accent = [[SparksGlassCard alloc] initWithCardTitle:@"主题色"];
    UIView *swatchRow = [[UIView alloc] init];
    swatchRow.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *swatches = [[UIStackView alloc] init];
    swatches.axis = UILayoutConstraintAxisHorizontal;
    swatches.spacing = 10;
    swatches.distribution = UIStackViewDistributionEqualSpacing;
    swatches.translatesAutoresizingMaskIntoConstraints = NO;
    [swatchRow addSubview:swatches];
    [swatches.leadingAnchor constraintEqualToAnchor:swatchRow.leadingAnchor].active = YES;
    [swatches.trailingAnchor constraintEqualToAnchor:swatchRow.trailingAnchor].active = YES;
    [swatches.centerYAnchor constraintEqualToAnchor:swatchRow.centerYAnchor].active = YES;
    for (NSString *hex in SpAccentPresets()) {
        unsigned rgb = 0;
        [[NSScanner scannerWithString:hex] scanHexInt:&rgb];
        UIControl *dot = [[UIControl alloc] init];
        dot.backgroundColor = [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                                               green:((rgb >> 8) & 0xFF) / 255.0
                                                blue:(rgb & 0xFF) / 255.0 alpha:1];
        dot.layer.cornerRadius = 14;
        dot.layer.borderColor = SpW(0.3).CGColor;
        dot.layer.borderWidth = 1;
        dot.translatesAutoresizingMaskIntoConstraints = NO;
        [swatches addArrangedSubview:dot];
        [dot.widthAnchor constraintEqualToConstant:28].active = YES;
        [dot.heightAnchor constraintEqualToConstant:28].active = YES;
        NSString *captured = hex;
        [dot addTarget:self action:@selector(accentPickedFromSender:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(dot, "hex", captured, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [swatchRow.heightAnchor constraintEqualToConstant:40].active = YES;
    [accent addRow:swatchRow];
    [accent addRow:SpRowSeparator()];
    [accent addRow:[SparksInfoRow actionWithTitle:@"自定义颜色" value:@"取色器" onTap:^{
        typeof(self) s = ws;
        if (!s) return;
        UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
        picker.title = @"主题色";
        picker.supportsAlpha = NO;
        picker.selectedColor = [SparksConfig shared].accentColor;
        picker.delegate = s;
        UIViewController *top = [s topVC];
        if (top) [top presentViewController:picker animated:YES completion:nil];
    }]];
    [accent addRow:SpRowSeparator()];
    [accent addRow:[SparksInfoRow switchWithTitle:@"标题字体跟随主题色" on:cfg.fontFollowsAccent onChange:^(BOOL on) {
        SparksConfig *c = [SparksConfig shared];
        c.fontFollowsAccent = on;
        [c save];
        typeof(self) s = ws;
        if (s) dispatch_async(dispatch_get_main_queue(), ^{ [s scheduleRebuild]; });
    }]];
    [self.stack addArrangedSubview:accent];

    // 悬浮球卡
    SparksGlassCard *ball = [[SparksGlassCard alloc] initWithCardTitle:@"悬浮球"];
    [ball addRow:[SparksInfoRow actionWithTitle:@"自定义图标" value:@"相册选图片 / GIF" onTap:^{
        typeof(self) s = ws;
        if (!s) return;
        [s pickImageToFilePrefix:@"sparks_ball_icon" completion:^(NSString *path) {
            typeof(self) s2 = ws;
            if (!s2) return;
            SparksConfig *c = [SparksConfig shared];
            c.ballIconPath = path ?: @"";
            [c save];
            [s2 applyBallIcon];
        }];
    }]];
    [ball addRow:SpRowSeparator()];
    [ball addRow:[SparksInfoRow actionWithTitle:@"恢复默认图标" value:@"火焰" onTap:^{
        typeof(self) s = ws;
        if (!s) return;
        [s removeFilesWithPrefix:@"sparks_ball_icon"];
        SparksConfig *c = [SparksConfig shared];
        c.ballIconPath = @"";
        [c save];
        [s applyBallIcon];
        SparksLog(@"悬浮球图标已恢复默认");
    }]];
    [ball addRow:SpRowSeparator()];
    [ball addRow:[self sliderRowTitle:[NSString stringWithFormat:@"大小 %.0f", [self currentBallSize]]
                                 value:[self currentBallSize]
                                    min:16 max:80
                             onChange:^(double v) {
        typeof(self) s = ws;
        if (!s) return;
        [SparksConfig shared].ballSize = v;
        [s resizeBallTo:v rebuildIcon:NO];
    } onEnd:^{
        typeof(self) s = ws;
        if (!s) return;
        [[SparksConfig shared] save];
        [s applyBallIcon];
    }]];
    [self.stack addArrangedSubview:ball];

    // 面板卡
    SparksGlassCard *panelCard = [[SparksGlassCard alloc] initWithCardTitle:@"面板"];
    NSArray<NSString *> *backdrops = @[@"关闭", @"深色半透明", @"玻璃材质"];
    [panelCard addRow:[SparksInfoRow actionWithTitle:@"面板底衬"
                                               value:backdrops[MIN(MAX(cfg.panelBackdrop, 0), 2)]
                                               onTap:^{
        typeof(self) s = ws;
        if (!s) return;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"面板底衬"
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSInteger i = 0; i < backdrops.count; i++) {
            [ac addAction:[UIAlertAction actionWithTitle:backdrops[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                SparksConfig *c = [SparksConfig shared];
                c.panelBackdrop = i;
                [c save];
                typeof(self) s2 = ws;
                if (s2) {
                    [s2 applyPanelBackground];
                    dispatch_async(dispatch_get_main_queue(), ^{ [s2 scheduleRebuild]; });
                }
            }]];
        }
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *top = [s topVC];
        if (top) {
            ac.popoverPresentationController.sourceView = top.view;
            [top presentViewController:ac animated:YES completion:nil];
        }
    }]];
    [panelCard addRow:SpRowSeparator()];
    [panelCard addRow:[self sliderRowTitle:[NSString stringWithFormat:@"宽度 %.0f", cfg.panelW]
                                     value:cfg.panelW min:280 max:screen.size.width - 16
                                 onChange:^(double v) {
        typeof(self) s = ws;
        if (!s) return;
        [SparksConfig shared].panelW = v;
        [s applyPanelSize];
    } onEnd:^{
        [[SparksConfig shared] save];
    }]];
    [panelCard addRow:SpRowSeparator()];
    [panelCard addRow:[self sliderRowTitle:[NSString stringWithFormat:@"高度 %.0f", cfg.panelH]
                                     value:cfg.panelH min:420 max:screen.size.height - 80
                                 onChange:^(double v) {
        typeof(self) s = ws;
        if (!s) return;
        [SparksConfig shared].panelH = v;
        [s applyPanelSize];
    } onEnd:^{
        [[SparksConfig shared] save];
    }]];
    [panelCard addRow:SpRowSeparator()];
    [panelCard addRow:[self sliderRowTitle:[NSString stringWithFormat:@"卡片透明度 %.0f%%", cfg.cardAlpha * 100]
                                     value:cfg.cardAlpha min:0.4 max:1.0
                                 onChange:^(double v) {
        typeof(self) s = ws;
        if (!s) return;
        [SparksConfig shared].cardAlpha = v;
    } onEnd:^{
        [[SparksConfig shared] save];
        typeof(self) s = ws;
        if (s) [s refreshChrome];   // 卡片/顶栏浓度需重建生效
    }]];
    [panelCard addRow:SpRowSeparator()];
    [panelCard addRow:[SparksInfoRow actionWithTitle:@"面板背景图" value:@"相册选图片" onTap:^{
        typeof(self) s = ws;
        if (!s) return;
        [s pickImageToFilePrefix:@"sparks_panel_bg" completion:^(NSString *path) {
            typeof(self) s2 = ws;
            if (!s2) return;
            SparksConfig *c = [SparksConfig shared];
            c.panelBgPath = path ?: @"";
            [c save];
            [s2 applyPanelBackground];
            [s2 scheduleRebuild];   // 状态签名含 bg 标记,同步刷新防后续误判
        }];
    }]];
    [panelCard addRow:SpRowSeparator()];
    [panelCard addRow:[SparksInfoRow actionWithTitle:@"清除背景图" value:@"" onTap:^{
        typeof(self) s = ws;
        if (!s) return;
        [s removeFilesWithPrefix:@"sparks_panel_bg"];
        SparksConfig *c = [SparksConfig shared];
        c.panelBgPath = @"";
        [c save];
        [s applyPanelBackground];
        [s scheduleRebuild];
    }]];
    [self.stack addArrangedSubview:panelCard];

    // 动画卡
    SparksGlassCard *anim = [[SparksGlassCard alloc] initWithCardTitle:@"开合动画"];
    [anim addRow:[SparksInfoRow actionWithTitle:@"预设"
                                          value:SpAnimPresetNames()[MIN(MAX(cfg.animPreset, 0), 4)]
                                          onTap:^{
        typeof(self) s = ws;
        if (!s) return;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"开合动画"
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray<NSString *> *names = SpAnimPresetNames();
        for (NSInteger i = 0; i < names.count; i++) {
            [ac addAction:[UIAlertAction actionWithTitle:names[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                SparksConfig *c = [SparksConfig shared];
                c.animPreset = i;
                [c save];
                SparksLog(@"开合动画:%@", names[i]);
                typeof(self) s2 = ws;
                if (s2) dispatch_async(dispatch_get_main_queue(), ^{ [s2 scheduleRebuild]; });
            }]];
        }
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *top = [s topVC];
        if (top) {
            ac.popoverPresentationController.sourceView = top.view;
            [top presentViewController:ac animated:YES completion:nil];
        }
    }]];
    [anim addRow:SpRowSeparator()];
    [anim addRow:[self sliderRowTitle:[NSString stringWithFormat:@"速率 x%.2f", cfg.animSpeed]
                                 value:cfg.animSpeed min:0.3 max:2.5
                             onChange:^(double v) {
        [SparksConfig shared].animSpeed = v;
    } onEnd:^{
        [[SparksConfig shared] save];
    }]];
    [self.stack addArrangedSubview:anim];

    // 提示卡
    SparksGlassCard *toast = [[SparksGlassCard alloc] initWithCardTitle:@"成功提示"];
    [toast addRow:[SparksInfoRow switchWithTitle:@"续火花成功浮条" on:cfg.toastOn onChange:^(BOOL on) {
        SparksConfig *c = [SparksConfig shared];
        c.toastOn = on;
        [c save];
    }]];
    [toast addRow:SpRowSeparator()];
    [toast addRow:[self sliderRowTitle:[NSString stringWithFormat:@"距顶部 %.0f", cfg.toastOffsetY]
                                 value:cfg.toastOffsetY min:60 max:screen.size.height - 160
                             onChange:^(double v) {
        [SparksConfig shared].toastOffsetY = v;
    } onEnd:^{
        [[SparksConfig shared] save];
    }]];
    [toast addRow:SpRowSeparator()];
    [toast addRow:[SparksInfoRow actionWithTitle:@"预览提示样式" value:@"也可直接拖动浮条" onTap:^{
        typeof(self) s = ws;
        if (s) [s showToast:@"🔥 预览:已给好友续火花"];
    }]];
    [self.stack addArrangedSubview:toast];

    // 后台卡
    SparksGlassCard *bg = [[SparksGlassCard alloc] initWithCardTitle:@"后台"];
    [bg addRow:[SparksInfoRow switchWithTitle:@"后台保活(静音循环播放)" on:cfg.keepAlive onChange:^(BOOL on) {
        SparksConfig *c = [SparksConfig shared];
        c.keepAlive = on;
        [c save];
        [[SparksEngine shared] setKeepAliveEnabled:on];
    }]];
    [bg addRow:SpRowSeparator()];
    [bg addRow:[SparksInfoRow switchWithTitle:@"后台也续火花" on:cfg.backgroundSend
                                     onChange:^(BOOL on) {
        SparksConfig *c = [SparksConfig shared];
        c.backgroundSend = on;
        [c save];
        SparksLog(@"后台续火花:%@%@",
                  on ? @"开(需同时开启保活)" : @"关",
                  (on && !c.keepAlive) ? @" ⚠️ 保活未开,实际不会在后台执行" : @"");
    }]];
    [bg addRow:SpRowSeparator()];
    [bg addRow:[SparksInfoRow switchWithTitle:@"后台静默(不跳聊天页)" on:cfg.bgSilentSend
                                     onChange:^(BOOL on) {
        SparksConfig *c = [SparksConfig shared];
        c.bgSilentSend = on;
        [c save];
        SparksLog(@"后台静默:%@%@",
                  on ? @"开(前台到点等待,退后台自动发)" : @"关(前台到点直接发,会跳聊天页)",
                  (on && !(c.keepAlive && c.backgroundSend)) ? @" ⚠️ 需同时开保活+后台续火花,否则自动降级为前台发送" : @"");
    }]];
    [self.stack addArrangedSubview:bg];
}

#pragma mark - 设置页

- (void)buildSettingsTab {
    SparksConfig *cfg = [SparksConfig shared];
    __weak typeof(self) ws = self;
    // 定时
    SparksGlassCard *timing = [[SparksGlassCard alloc] initWithCardTitle:@"定时"];
    [timing addRow:[[SparksFieldRow alloc] initWithTitle:@"发送时间" placeholder:@"08:30 或 08:30-21:30" secure:NO
                                                    text:cfg.dailyTime onChange:^(NSString *v) {
        SparksConfig *c = [SparksConfig shared];
        NSRange dash = [v rangeOfString:@"-"];
        __block BOOL ok = NO;
        if (dash.location == NSNotFound) {
            NSArray *hm = [v componentsSeparatedByString:@":"];
            ok = hm.count == 2 && ((NSString *)hm[0]).integerValue >= 0 && ((NSString *)hm[0]).integerValue < 24
                              && ((NSString *)hm[1]).integerValue >= 0 && ((NSString *)hm[1]).integerValue < 60;
        } else {
            NSArray *parts = [v componentsSeparatedByString:@"-"];
            if (parts.count == 2) {
                for (NSString *p in parts) {
                    NSArray *hm = [p componentsSeparatedByString:@":"];
                    ok = hm.count == 2 && ((NSString *)hm[0]).integerValue >= 0 && ((NSString *)hm[0]).integerValue < 24
                                      && ((NSString *)hm[1]).integerValue >= 0 && ((NSString *)hm[1]).integerValue < 60;
                    if (!ok) break;
                }
            }
        }
        if (ok) {
            c.dailyTime = v;
            if (dash.location != NSNotFound) {
                SparksLog(@"⏰ 时间段 %@:今日抽样 %@", v, c.todayEffectiveTime ?: @"?");
            }
        } else {
            SparksLog(@"⚠️ 格式应为 HH:mm 或 HH:mm-HH:mm,未保存");
        }
        [c save];
    }]];
    [timing addRow:SpRowSeparator()];
    [timing addRow:[[SparksFieldRow alloc] initWithTitle:@"发送间隔(秒)" placeholder:@"75" secure:NO
                                                    text:[NSString stringWithFormat:(cfg.interval < 10 ? @"%.2f" : @"%.0f"), cfg.interval] onChange:^(NSString *v) {
        double d = v.doubleValue;
        if (d >= 0.1 && d <= 3600) [SparksConfig shared].interval = d;   // 允许亚秒级密集发送
        else SparksLog(@"⚠️ 间隔需在 15~3600 秒,未保存");
        [[SparksConfig shared] save];
    }]];
    [timing addRow:SpRowSeparator()];
    [timing addRow:[SparksInfoRow actionWithTitle:@"时间显示"
                                             value:cfg.time12h ? @"12小时制(上午/中午/下午/晚上)" : @"24小时制"
                                              onTap:^{
        typeof(self) s = ws;
        if (!s) return;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"时间显示制式"
                                                                    message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        [ac addAction:[UIAlertAction actionWithTitle:@"24小时制(08:30)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            typeof(self) s2 = ws;
            if (!s2) return;
            SparksConfig *c = [SparksConfig shared];
            c.time12h = NO;
            [c save];
            [s2 scheduleRebuild];
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"12小时制(上午 8:30 / 中午 12:00)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            typeof(self) s2 = ws;
            if (!s2) return;
            SparksConfig *c = [SparksConfig shared];
            c.time12h = YES;
            [c save];
            [s2 scheduleRebuild];
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *top = [s topVC];
        if (top) {
            ac.popoverPresentationController.sourceView = top.view;
            [top presentViewController:ac animated:YES completion:nil];
        }
    }]];
    [self.stack addArrangedSubview:timing];

    // AI 服务
    SparksGlassCard *ai = [[SparksGlassCard alloc] initWithCardTitle:@"AI 服务"];
    [ai addRow:[SparksInfoRow actionWithTitle:@"接口预设" value:cfg.aiModel onTap:^{
        typeof(self) s = ws;
        if (!s) return;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"常用接口"
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *p in SpAIPresets()) {
            NSString *name = [NSString stringWithFormat:@"%@ · %@", p[@"name"], p[@"model"]];
            [ac addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                SparksConfig *c = [SparksConfig shared];
                c.aiURL = p[@"url"];
                c.aiModel = p[@"model"];
                [c save];
                SparksLog(@"AI 预设:%@(%@)", p[@"name"], p[@"model"]);
                typeof(self) s2 = ws;
                if (s2) dispatch_async(dispatch_get_main_queue(), ^{ [s2 scheduleRebuild]; });
            }]];
        }
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *top = [s topVC];
        if (top) {
            ac.popoverPresentationController.sourceView = top.view;
            [top presentViewController:ac animated:YES completion:nil];
        }
    }]];
    [ai addRow:SpRowSeparator()];
    [ai addRow:[[SparksFieldRow alloc] initWithTitle:@"接口地址" placeholder:@"https://…" secure:NO
                                                text:cfg.aiURL onChange:^(NSString *v) {
        if ([v.lowercaseString hasPrefix:@"https://"]) [SparksConfig shared].aiURL = v;
        else SparksLog(@"⚠️ 地址必须 https 开头,未保存");
        [[SparksConfig shared] save];
    }]];
    [ai addRow:SpRowSeparator()];
    [ai addRow:[[SparksFieldRow alloc] initWithTitle:@"API Key" placeholder:@"sk-…" secure:YES
                                                text:cfg.aiKey onChange:^(NSString *v) {
        [SparksConfig shared].aiKey = v;
        [[SparksConfig shared] save];
    }]];
    [ai addRow:SpRowSeparator()];
    [ai addRow:[[SparksFieldRow alloc] initWithTitle:@"模型" placeholder:@"glm-4-flash" secure:NO
                                                text:cfg.aiModel onChange:^(NSString *v) {
        if (v.length) [SparksConfig shared].aiModel = v;
        [[SparksConfig shared] save];
    }]];
    [ai addRow:SpRowSeparator()];
    [ai addRow:[[SparksFieldRow alloc] initWithTitle:@"风格补充要求" placeholder:@"比如:偶尔聊聊游戏" secure:NO
                                                text:cfg.aiExtra onChange:^(NSString *v) {
        [SparksConfig shared].aiExtra = v;
        [[SparksConfig shared] save];
    }]];
    [ai addRow:SpRowSeparator()];
    [ai addRow:[SparksInfoRow actionWithTitle:@"测试接入" value:@"生成一条试试" onTap:^{
        typeof(self) s = ws;
        if (!s) return;
        [SparksAI testGenerateWithCompletion:^(NSString *text, NSString *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) s2 = ws;
                if (!s2) return;
                [s2 showToast:text ? [NSString stringWithFormat:@"✅ 接入成功:%@", text] : [NSString stringWithFormat:@"❌ 接入失败:%@", error ?: @"看日志"]];
                SparksLog(@"AI 接入测试:%@", text ? [NSString stringWithFormat:@"成功「%@」", text] : (error ?: @"失败"));
            });
        }];
    }]];
    [self.stack addArrangedSubview:ai];

    // v2.14:兜底文案/媒体火花/个人资料三卡已删(用户点名)——
    // 兜底走默认+目标级独立文案;媒体走目标级"发送图片";个人资料在插件主页点头像/昵称区编辑

    // 高级/关于
    SparksGlassCard *about = [[SparksGlassCard alloc] initWithCardTitle:@"高级"];
    [about addRow:[SparksInfoRow switchWithTitle:@"透传捕获的 userInfo" on:cfg.relayUserInfo onChange:^(BOOL on) {
        [SparksConfig shared].relayUserInfo = on;
        [[SparksConfig shared] save];
    }]];
    [about addRow:SpRowSeparator()];
    [about addRow:[SparksInfoRow actionWithTitle:@"备份配置" value:@"导出 JSON 分享" onTap:^{
        typeof(self) s = ws;
        if (s) [s exportBackup];
    }]];
    [about addRow:SpRowSeparator()];
    [about addRow:[SparksInfoRow actionWithTitle:@"恢复配置" value:@"粘贴 JSON" onTap:^{
        typeof(self) s = ws;
        if (s) [s importBackup];
    }]];
    [about addRow:SpRowSeparator()];
    [about addRow:[SparksInfoRow actionWithTitle:@"检查更新" value:@"下载完调系统分享" onTap:^{
        typeof(self) s = ws;
        if (s) [s checkUpdate];
    }]];
    [about addRow:SpRowSeparator()];
    [about addRow:[SparksInfoRow actionWithTitle:@"自愿捐赠" value:@"微信赞赏码" onTap:^{
        typeof(self) s = ws;
        if (s) [s showDonate];
    }]];
    [about addRow:SpRowSeparator()];
    [about addRow:[SparksInfoRow infoWithTitle:@"关于"
                                          value:[NSString stringWithFormat:@"v%@ · liudubin · 构建 %@(北京时间)",
                                                  SPARKS_VER, SPARKS_BUILD.length ? SPARKS_BUILD : @"-"]]];
    UILabel *tip = [[UILabel alloc] init];
    tip.text = @"仅供个人学习研究;自动发消息有风控风险,请控制目标数量与频率。";
    tip.numberOfLines = 0;
    tip.font = [UIFont systemFontOfSize:11];
    tip.textColor = SpW(0.68);
    tip.translatesAutoresizingMaskIntoConstraints = NO;
    [about addRow:tip];
    [tip.heightAnchor constraintGreaterThanOrEqualToConstant:30].active = YES;
    [self.stack addArrangedSubview:about];
}

#pragma mark - 日志页

- (void)buildLogTab {
    SparksGlassCard *card = [[SparksGlassCard alloc] initWithCardTitle:@"运行日志"];

    UIView *body = [[UIView alloc] init];
    body.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *ops = [[UIStackView alloc] init];
    ops.axis = UILayoutConstraintAxisHorizontal;
    ops.spacing = 8;
    ops.distribution = UIStackViewDistributionFillEqually;
    ops.translatesAutoresizingMaskIntoConstraints = NO;
    [body addSubview:ops];
    [ops.topAnchor constraintEqualToAnchor:body.topAnchor].active = YES;
    [ops.leadingAnchor constraintEqualToAnchor:body.leadingAnchor].active = YES;
    [ops.trailingAnchor constraintEqualToAnchor:body.trailingAnchor].active = YES;
    [ops.heightAnchor constraintEqualToConstant:28].active = YES;

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [copyBtn setTitle:@"复制日志" forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [copyBtn setTitleColor:SpW(0.9) forState:UIControlStateNormal];
    copyBtn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    copyBtn.layer.cornerRadius = 14;
    copyBtn.layer.cornerCurve = kCACornerCurveContinuous;
    [copyBtn addTarget:self action:@selector(copyLog) forControlEvents:UIControlEventTouchUpInside];
    [ops addArrangedSubview:copyBtn];

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    [clear setTitle:@"清空" forState:UIControlStateNormal];
    clear.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [clear setTitleColor:SpW(0.9) forState:UIControlStateNormal];
    clear.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    clear.layer.cornerRadius = 14;
    clear.layer.cornerCurve = kCACornerCurveContinuous;
    [clear addTarget:self action:@selector(clearLog) forControlEvents:UIControlEventTouchUpInside];
    [ops addArrangedSubview:clear];

    UITextView *tv = [[UITextView alloc] init];
    tv.editable = NO;
    tv.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:11];
    tv.textColor = SpW(0.92);
    tv.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    tv.layer.cornerRadius = 12;
    tv.layer.cornerCurve = kCACornerCurveContinuous;
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [body addSubview:tv];
    [tv.topAnchor constraintEqualToAnchor:ops.bottomAnchor constant:8].active = YES;
    [tv.leadingAnchor constraintEqualToAnchor:body.leadingAnchor].active = YES;
    [tv.trailingAnchor constraintEqualToAnchor:body.trailingAnchor].active = YES;
    [tv.bottomAnchor constraintEqualToAnchor:body.bottomAnchor].active = YES;
    [tv.heightAnchor constraintEqualToConstant:340].active = YES;
    self.logTextView = tv;

    [card addRow:body];
    [self.stack addArrangedSubview:card];
    [self refreshLog];
}

- (void)copyLog {
    UIPasteboard.generalPasteboard.string = SparksLogSnapshot();
    [self showToast:@"📋 日志已复制"];
    SparksLog(@"日志已复制到剪贴板");
}

- (void)clearLog {
    SparksClearLogSnapshot();
    if (self.logTextView) self.logTextView.text = @"";
    SparksLog(@"日志已清空");
}

#pragma mark - 滑杆行

- (UIView *)sliderRowTitle:(NSString *)title value:(double)value min:(double)min max:(double)max
                  onChange:(void (^)(double v))change onEnd:(void (^)(void))end {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *label = SpMakeTitleLabel(title, 13);
    [row addSubview:label];
    [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor].active = YES;
    [label.topAnchor constraintEqualToAnchor:row.topAnchor constant:6].active = YES;

    UISlider *slider = [[UISlider alloc] init];
    slider.minimumValue = min;
    slider.maximumValue = max;
    slider.value = value;
    slider.minimumTrackTintColor = SpAccent();
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:slider];
    [slider.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:4].active = YES;
    [slider.leadingAnchor constraintEqualToAnchor:row.leadingAnchor].active = YES;
    [slider.trailingAnchor constraintEqualToAnchor:row.trailingAnchor].active = YES;
    [slider.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-6].active = YES;
    [slider.heightAnchor constraintEqualToConstant:28].active = YES;

    objc_setAssociatedObject(slider, "label", label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(slider, "fmt", [title copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(slider, "change", [change copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(slider, "end", [end copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [slider addTarget:self action:@selector(spSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [slider addTarget:self action:@selector(spSliderDone:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return row;
}

- (void)spSliderChanged:(UISlider *)slider {
    void (^change)(double) = objc_getAssociatedObject(slider, "change");
    if (change) change(slider.value);
    UILabel *label = objc_getAssociatedObject(slider, "label");
    NSString *fmt = objc_getAssociatedObject(slider, "fmt");
    if ([label isKindOfClass:[UILabel class]] && fmt.length) {
        NSRange r = [fmt rangeOfString:@"[0-9]+\\.?[0-9]*" options:NSRegularExpressionSearch];
        if (r.location != NSNotFound) {
            NSString *rep = [fmt containsString:@"x"]
                ? [NSString stringWithFormat:@"x%.1f", slider.value]
                : [NSString stringWithFormat:@"%.0f", slider.value];
            label.text = [fmt stringByReplacingCharactersInRange:r withString:rep];
        }
    }
}

- (void)spSliderDone:(UISlider *)slider {
    void (^end)(void) = objc_getAssociatedObject(slider, "end");
    if (end) end();
}

- (void)resizeBallTo:(CGFloat)size rebuildIcon:(BOOL)rebuild {
    UIView *wrapper = self.ballWrapper;
    if (!wrapper) return;
    CGPoint c = wrapper.center;
    CGRect b = [UIScreen mainScreen].bounds;
    c.x = MAX(size / 2 + 6, MIN(b.size.width - size / 2 - 6, c.x));
    c.y = MAX(64, MIN(b.size.height - 48, c.y));
    wrapper.layer.cornerRadius = size / 2;
    wrapper.frame = CGRectMake(c.x - size / 2, c.y - size / 2, size, size);
    self.ballIconHolder.layer.cornerRadius = size / 2;   // 裁切圆随尺寸同步,避免错位
    if (rebuild) [self applyBallIcon];
}

#pragma mark - 主题色选择

- (void)accentPickedFromSender:(UIControl *)sender {
    NSString *hex = objc_getAssociatedObject(sender, "hex");
    if (![hex isKindOfClass:[NSString class]]) return;
    SparksConfig *cfg = [SparksConfig shared];
    cfg.accentHex = hex;
    [cfg save];
    SparksLog(@"主题色:#%@", hex);
    [self refreshAccentLive];
}

#pragma mark - UIColorPickerViewControllerDelegate

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    NSString *hex = objc_getAssociatedObject(viewController, "hex");
    [viewController dismissViewControllerAnimated:YES completion:nil];
    if (![hex isKindOfClass:[NSString class]] || !hex.length) return;
    SparksConfig *cfg = [SparksConfig shared];
    cfg.accentHex = hex;
    [cfg save];
    SparksLog(@"主题色:#%@(取色器)", hex);
    [self refreshAccentLive];
}

- (void)colorPickerViewController:(UIColorPickerViewController *)viewController
                    didSelectColor:(UIColor *)color continuously:(BOOL)continuously {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [color getRed:&r green:&g blue:&b alpha:&a];
    NSString *hex = [NSString stringWithFormat:@"%02lX%02lX%02lX",
                     (unsigned long)(r * 255), (unsigned long)(g * 255), (unsigned long)(b * 255)];
    objc_setAssociatedObject(viewController, "hex", hex, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - 相册选择(修复:临时文件必须在回调内同步复制)

- (NSString *)storeDir {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

- (void)removeFilesWithPrefix:(NSString *)prefix {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [self storeDir];
    for (NSString *f in [[fm contentsOfDirectoryAtPath:dir error:nil] copy]) {
        if ([f hasPrefix:[NSString stringWithFormat:@"%@.", prefix]]) {
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
        }
    }
}

- (void)pickImageToFilePrefix:(NSString *)prefix completion:(void (^)(NSString *path))done {
    self.pickPrefix = prefix;
    self.pickDone = [done copy];
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = [PHPickerFilter imagesFilter];
    config.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    UIViewController *top = [self topVC];
    if (top) [top presentViewController:picker animated:YES completion:nil];
}

+ (NSString *)spMediaStorePathForExt:(NSString *)ext index:(NSUInteger)idx {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    long long ms = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
    return [dir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"sparks_media_%lld_%lu.%@", ms, (unsigned long)idx, ext.length ? ext : @"img"]];
}

- (void)picker:(PHPickerViewController *)picker
didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];

    if (self.pickMediaMulti) {
        self.pickMediaMulti = NO;
        NSMutableArray *paths = [NSMutableArray array];
        dispatch_group_t group = dispatch_group_create();
        [results enumerateObjectsUsingBlock:^(PHPickerResult *r, NSUInteger i, BOOL *stop) {
            NSItemProvider *provider = r.itemProvider;
            if (!provider) return;
            NSString *gifUTI = nil;
            for (NSString *reg in provider.registeredTypeIdentifiers) {
                if ([[reg lowercaseString] containsString:@"gif"]) { gifUTI = reg; break; }
            }
            NSString *uti = gifUTI ?: UTTypeImage.identifier;
            dispatch_group_enter(group);
            [provider loadFileRepresentationForTypeIdentifier:uti completionHandler:^(NSURL *url, NSError *err) {
                if (!url) {
                    dispatch_group_leave(group);
                    return;
                }
                NSString *ext = url.pathExtension.length ? url.pathExtension.lowercaseString : @"img";
                NSString *out = [SparksPanel spMediaStorePathForExt:ext index:i];
                NSError *cerr = nil;
                BOOL ok = [[NSFileManager defaultManager] copyItemAtPath:url.path toPath:out error:&cerr];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ok) [paths addObject:out];
                    dispatch_group_leave(group);
                });
            }];
        }];
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            if (!paths.count) {
                SparksLog(@"⚠️ 未入库任何媒体");
                return;
            }
            SparksConfig *c = [SparksConfig shared];
            [c.mediaFiles addObjectsFromArray:paths];
            [c save];
            SparksLog(@"✅ 媒体库 +%lu(共 %lu)", (unsigned long)paths.count, (unsigned long)c.mediaFiles.count);
            SparksPanel *panel = [SparksPanel spShared];
            [panel scheduleRebuild];
        });
        return;
    }

    NSItemProvider *provider = results.firstObject.itemProvider;
    if (!provider) return;

    NSString *prefix = self.pickPrefix ?: @"sparks_img";
    NSString *gifUTI = nil;
    for (NSString *registered in provider.registeredTypeIdentifiers) {
        if ([[registered lowercaseString] containsString:@"gif"]) {
            gifUTI = registered;
            break;
        }
    }
    if (gifUTI) {
        [provider loadFileRepresentationForTypeIdentifier:gifUTI completionHandler:^(NSURL *url, NSError *err) {
            if (url) {
                [SparksPanel spStorePickedFile:url prefix:prefix fromData:nil];
            } else {
                [SparksPanel spLoadGeneric:provider prefix:prefix];
            }
        }];
    } else {
        [SparksPanel spLoadGeneric:provider prefix:prefix];
    }
}

+ (void)spLoadGeneric:(NSItemProvider *)provider prefix:(NSString *)prefix {
    [provider loadFileRepresentationForTypeIdentifier:UTTypeImage.identifier
                                    completionHandler:^(NSURL *url, NSError *err) {
        if (url) {
            [SparksPanel spStorePickedFile:url prefix:prefix fromData:nil];
            return;
        }
        [provider loadDataRepresentationForTypeIdentifier:UTTypeImage.identifier
                                        completionHandler:^(NSData *data, NSError *err2) {
            if (!data.length) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    SparksLog(@"⚠️ 读取相册文件失败:%@", err2.localizedDescription ?: @"未知");
                });
                return;
            }
            [SparksPanel spStorePickedFile:nil prefix:prefix fromData:data];
        }];
    }];
}

// 必须在回调线程内同步落盘(PHPicker 临时文件回调返回即失效——v1.2 失效根因)
+ (void)spStorePickedFile:(NSURL *)tmpUrl prefix:(NSString *)prefix fromData:(NSData *)data {
    NSString *ext = nil;
    NSData *payload = data;
    if (tmpUrl) {
        ext = tmpUrl.pathExtension.length ? tmpUrl.pathExtension.lowercaseString : nil;
        payload = [NSData dataWithContentsOfURL:tmpUrl];
    }
    if (!payload.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SparksLog(@"⚠️ 选取文件内容为空");
        });
        return;
    }
    if (!ext.length) {
        // magic bytes 判类型
        const uint8_t *b = (const uint8_t *)payload.bytes;
        if (payload.length >= 6 && b[0] == 'G' && b[1] == 'I' && b[2] == 'F') ext = @"gif";
        else if (payload.length >= 2 && b[0] == 0xFF && b[1] == 0xD8) ext = @"jpg";
        else if (payload.length >= 8 && b[0] == 0x89 && b[1] == 'P') ext = @"png";
        else if (payload.length >= 12 && b[8] == 'H' && b[9] == 'E' && b[10] == 'I') ext = @"heic";
        else ext = @"img";
    }

    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *out = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", prefix, ext]];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *f in [[fm contentsOfDirectoryAtPath:dir error:nil] copy]) {
        if ([f hasPrefix:[NSString stringWithFormat:@"%@.", prefix]]) {
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
        }
    }
    if (![payload writeToFile:out atomically:YES]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SparksLog(@"⚠️ 保存文件失败:%@", out);
        });
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        SparksLog(@"✅ 已保存 %@(%@, %lu KB)", out.lastPathComponent, ext, (unsigned long)(payload.length / 1024));
        SparksPanel *panel = [SparksPanel spShared];
        void (^done)(NSString *) = panel.pickDone;
        panel.pickDone = nil;
        panel.pickPrefix = nil;
        if (done) done(out);
    });
}

#pragma mark - 检查更新(公开镜像 Release;下载完系统分享;包自动删除)

// 主题色实时生效:内容原地重建(不关面板),dock/头部ID/悬浮球即时重着色
- (void)refreshAccentLive {
    self.lastSig = nil;                 // 强制重建内容(开关/按钮/图标块全部重读主题色)
    [self rebuildContent];
    [self.seg setIndex:self.tab animated:NO];   // dock 选中图标重着色
    [self applyBallIcon];               // 默认火焰图标随主题色
}

// 首页头部快捷编辑资料(点头像/昵称弹出)
// 点头像:直达相册换头像(v2.14.4 与昵称分开设置)
- (void)avatarEditTapped {
    __weak typeof(self) ws = self;
    [self pickImageToFilePrefix:@"sparks_avatar" completion:^(NSString *path) {
        typeof(self) s = ws;
        if (!s) return;
        SparksConfig *c = [SparksConfig shared];
        c.avatarPath = path ?: @"";
        [c save];
        [s refreshChrome];
    }];
}

// 点昵称区:文字资料菜单(昵称/签名)
- (void)profileEditTapped {
    __weak typeof(self) ws = self;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"文字资料"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"修改昵称" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        typeof(self) s = ws;
        if (!s) return;
        [s editProfileField:@"昵称" key:@"nick" current:[SparksConfig shared].nickName];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"修改个性签名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        typeof(self) s = ws;
        if (!s) return;
        [s editProfileField:@"个性签名" key:@"sign" current:[SparksConfig shared].signature];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *top = [self topVC];
    if (top) {
        ac.popoverPresentationController.sourceView = top.view;
        [top presentViewController:ac animated:YES completion:nil];
    }
}

// 单字段资料编辑弹窗(key: nick/sign)
- (void)editProfileField:(NSString *)title key:(NSString *)key current:(NSString *)current {
    __weak typeof(self) ws = self;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = current ?: @"";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        typeof(self) s = ws;
        if (!s) return;
        SparksConfig *c = [SparksConfig shared];
        NSString *v = ac.textFields.firstObject.text ?: @"";
        if ([key isEqualToString:@"nick"]) c.nickName = v;
        else c.signature = v;
        [c save];
        [s refreshChrome];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *top = [self topVC];
    if (top) [top presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 自愿捐赠(赞赏码随包安装,弹窗展示)

// deb layout 资产:安装后落在越狱根下 Library/SparksHelper/
- (NSString *)donateQRPath {
    NSMutableArray *cands = [NSMutableArray array];
    // RootHide/Relaxin 的 bootstrap 前缀随机化(反检测),/var/jb 不存在——
    // 从自身 dylib 安装位置反推越狱根,对任意前缀成立
    NSString *bp = [NSBundle bundleForClass:[SparksConfig class]].bundlePath;
    if ([bp hasSuffix:@".dylib"]) {
        NSString *root = bp;   // <根>/Library/MobileSubstrate/DynamicLibraries/SparksHelper.dylib
        for (int i = 0; i < 4; i++) root = [root stringByDeletingLastPathComponent];
        [cands addObject:[root stringByAppendingPathComponent:@"Library/SparksHelper/donate_qr.jpg"]];
    }
    [cands addObjectsFromArray:@[
        @"/var/jb/Library/SparksHelper/donate_qr.jpg",
        @"/Library/SparksHelper/donate_qr.jpg",
    ]];
    for (NSString *p in cands) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
            SparksLog(@"捐赠码命中:%@", p);
            return p;
        }
    }
    SparksLog(@"⚠️ 捐赠码未找到,候选:%@", cands);
    return nil;
}

- (void)showDonate {
    [self hideDonate];
    NSString *path = [self donateQRPath];
    UIImage *img = path ? [UIImage imageWithContentsOfFile:path] : nil;
    if (!img) {
        // 资产缺失兜底:打开捐赠链接
        NSURL *u = [NSURL URLWithString:[SparksConfig shared].donateURL];
        if (SparksURLOK(u)) {
            [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
        } else {
            SparksLog(@"⚠️ 赞赏码缺失且捐赠链接无效");
            [self showToast:@"❌ 赞赏码未安装,看日志"];
        }
        return;
    }
    if (!self.panelWindow) return;

    CGRect b = self.panelWindow.bounds;
    UIView *shade = [[UIView alloc] initWithFrame:b];
    shade.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    shade.userInteractionEnabled = YES;

    CGFloat side = MIN(250, b.size.width - 80);
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((b.size.width - side - 32) / 2,
                                                            (b.size.height - side - 118) / 2,
                                                            side + 32, side + 118)];
    card.backgroundColor = [UIColor whiteColor];   // 赞赏码是白底图,必须垫白
    card.layer.cornerRadius = 22;
    card.layer.cornerCurve = kCACornerCurveContinuous;

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(0, 12, card.bounds.size.width, 22)];
    t.text = @"自愿捐赠";
    t.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    t.textColor = [UIColor blackColor];
    t.textAlignment = NSTextAlignmentCenter;
    [card addSubview:t];

    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(16, 44, side, side)];
    iv.image = img;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.layer.cornerRadius = 12;
    iv.layer.cornerCurve = kCACornerCurveContinuous;
    iv.clipsToBounds = YES;
    iv.userInteractionEnabled = YES;
    [card addSubview:iv];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(0, 44 + side + 4, card.bounds.size.width, 18)];
    sub.text = @"微信扫一扫 · 感谢支持 ❤️";
    sub.font = [UIFont systemFontOfSize:12];
    sub.textColor = [UIColor colorWithWhite:0 alpha:0.55];
    sub.textAlignment = NSTextAlignmentCenter;
    [card addSubview:sub];

    // 长按二维码:保存到相册(抖音内直接完成,不用另一台设备扫屏)
    UILongPressGestureRecognizer *saveLp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(saveDonateToAlbum:)];
    saveLp.minimumPressDuration = 0.5;
    [iv addGestureRecognizer:saveLp];
    objc_setAssociatedObject(iv, "img", img, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    saveBtn.frame = CGRectMake(16, 44 + side + 26, card.bounds.size.width - 32, 32);
    [saveBtn setTitle:@"保存到相册" forState:UIControlStateNormal];
    [saveBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    saveBtn.backgroundColor = [UIColor colorWithRed:0.95 green:0.55 blue:0.18 alpha:1.0];
    saveBtn.layer.cornerRadius = 16;
    saveBtn.layer.cornerCurve = kCACornerCurveContinuous;
    [saveBtn addTarget:self action:@selector(saveDonateToAlbum:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(saveBtn, "img", img, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [card addSubview:saveBtn];

    [shade addSubview:card];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideDonate)];
    [shade addGestureRecognizer:tap];

    [self.panelWindow.rootViewController.view addSubview:shade];
    [self.panelWindow.rootViewController.view bringSubviewToFront:shade];
    shade.alpha = 0;
    card.transform = CGAffineTransformMakeScale(0.9, 0.9);
    [UIView animateWithDuration:0.25 delay:0
         usingSpringWithDamping:0.8 initialSpringVelocity:0.5
                        options:0 animations:^{
        shade.alpha = 1;
        card.transform = CGAffineTransformIdentity;
    } completion:nil];
    self.donateView = shade;
}

- (void)hideDonate {
    [self.donateView removeFromSuperview];
    self.donateView = nil;
}

// 保存赞赏码到相册(按钮点按/长按二维码;Photos 库授权失败时提示去设置)
- (void)saveDonateToAlbum:(id)sender {
    UIImage *img = objc_getAssociatedObject(sender, "img");
    if (![img isKindOfClass:[UIImage class]]) return;
    void (^done)(BOOL, NSError *) = ^(BOOL ok, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                [self showToast:@"✅ 赞赏码已存到相册,微信里识别即可"];
                SparksLog(@"✅ 赞赏码已保存到相册");
            } else {
                SparksLog(@"⚠️ 赞赏码保存失败:%@", err.localizedDescription ?: @"无相册权限");
                [self showToast:@"❌ 保存失败,请允许抖音访问相册"];
            }
        });
    };
    if (@available(iOS 13, *)) {
        [[PHPhotoLibrary sharedPhotoLibrary]
            performChanges:^{ [PHAssetChangeRequest creationRequestForAssetFromImage:img]; }
        completionHandler:done];
    } else {
        done(NO, nil);
    }
}

- (void)checkUpdate {
    // fudai-ci 多插件混发,/latest 可能是别的插件:改拉列表,取"含 sparkshelper 资产"的最新一条
    NSURL *api = [NSURL URLWithString:@"https://api.github.com/repos/liudubin/fudai-ci/releases?per_page=100"];
    NSArray<NSString *> *hosts = SpUpdateHosts();
    if (!SparksURLOK(api) || ![hosts containsObject:api.host.lowercaseString]) {
        SparksLog(@"⚠️ 更新地址校验失败");
        [self showToast:@"❌ 更新地址校验失败"];
        return;
    }
    SparksLog(@"🔎 检查更新…");
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:api];
    req.timeoutInterval = 20;
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    __weak typeof(self) ws = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = ws;
            if (!s) return;
            if (err || !data) {
                SparksLog(@"⚠️ 检查更新失败:%@", err.localizedDescription ?: @"无数据");
                [s showToast:@"❌ 检查更新失败(网络),看日志"];
                return;
            }
            // HTTP 状态码先行:403=匿名限流(共享出口 IP 高发)、其余非 200 全部带码入日志
            if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
                NSInteger code = ((NSHTTPURLResponse *)resp).statusCode;
                if (code != 200) {
                    NSString *bodyStr = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
                    SparksLog(@"⚠️ 更新接口 HTTP %ld:%@", (long)code,
                              bodyStr.length > 200 ? [bodyStr substringToIndex:200] : (bodyStr ?: @"空"));
                    if (code == 403) {
                        [s showToast:@"❌ GitHub 接口限流(匿名 60 次/时),稍后再试"];
                    } else {
                        [s showToast:[NSString stringWithFormat:@"❌ 更新接口 HTTP %ld,看日志", (long)code]];
                    }
                    return;
                }
            }
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:[NSArray class]]) {
                NSString *bodyStr = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
                SparksLog(@"⚠️ 更新接口返回异常:%@", bodyStr.length > 200 ? [bodyStr substringToIndex:200] : (bodyStr ?: @"空"));
                [s showToast:@"❌ 更新接口返回异常,看日志"];
                return;
            }
            // 找最新一条含火花助手 Relaxin 包的 release
            NSString *tag = nil;
            NSString *assetURL = nil;
            for (NSDictionary *rel in (NSArray *)json) {
                if (![rel isKindOfClass:[NSDictionary class]]) continue;
                NSString *t = rel[@"tag_name"];
                if (![t isKindOfClass:[NSString class]] || !t.length) continue;
                for (NSDictionary *a in (rel[@"assets"] ?: @[])) {
                    NSString *n = a[@"name"];
                    // 兼容新旧命名:旧 sparkshelper-vX-Relaxin.deb / 新 抖音AI续火花助手_vX_Relaxin.deb
                    BOOL nameOk = [n containsString:@"sparkshelper-"] || [n containsString:@"续火花"];
                    BOOL suffixOk = [n hasSuffix:@"-Relaxin.deb"] || [n hasSuffix:@"_Relaxin.deb"];
                    if ([n isKindOfClass:[NSString class]] && nameOk && suffixOk) {
                        tag = t;
                        assetURL = a[@"browser_download_url"];
                        break;
                    }
                }
                if (tag) break;
            }
            if (!tag.length || ![assetURL isKindOfClass:[NSString class]] || !assetURL.length) {
                SparksLog(@"⚠️ 未找到火花助手的发布记录");
                [s showToast:@"❌ 未找到火花助手的发布,看日志"];
                return;
            }
            // 归一化比较(去掉 v 前缀与空白)
            NSString *cur = [SPARKS_VER stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *remote = [tag stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([remote hasPrefix:@"v"] || [remote hasPrefix:@"V"]) remote = [remote substringFromIndex:1];
            if ([cur hasPrefix:@"v"] || [cur hasPrefix:@"V"]) cur = [cur substringFromIndex:1];
            if ([remote isEqualToString:cur]) {
                [s showToast:[NSString stringWithFormat:@"✅ 已是最新版 v%@", SPARKS_VER]];
                SparksLog(@"已是最新版 v%@", SPARKS_VER);
                return;
            }
            SparksLog(@"⬇️ 发现新版 %@,开始下载…", tag);
            [s downloadUpdateFrom:assetURL tag:tag];
        });
    }];
    [task resume];
}

- (void)downloadUpdateFrom:(NSString *)urlString tag:(NSString *)tag {
    NSURL *url = [NSURL URLWithString:urlString];
    NSArray<NSString *> *hosts = SpUpdateHosts();
    if (!SparksURLOK(url) || ![hosts containsObject:url.host.lowercaseString]) {
        SparksLog(@"⚠️ 下载地址校验失败:%@", urlString);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 120;
    __weak typeof(self) ws = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                   completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = ws;
            if (!s) return;
            if (err || !data.length) {
                SparksLog(@"⚠️ 下载失败:%@", err.localizedDescription ?: @"空数据");
                [s showToast:@"❌ 下载失败,看日志"];
                return;
            }
            // GitHub 资产文件名强制 ASCII,中文包名落在下载保存的文件上(分享/存文件时可见)
            NSString *path = [NSTemporaryDirectory()
                stringByAppendingPathComponent:[NSString stringWithFormat:@"抖音AI续火花助手_%@_Relaxin.deb", tag]];
            if (![data writeToFile:path atomically:YES]) {
                SparksLog(@"⚠️ 更新包写入失败");
                return;
            }
            SparksLog(@"✅ 下载完成:%@ (%lu KB),调起系统分享", tag, (unsigned long)(data.length / 1024));
            NSURL *fileURL = [NSURL fileURLWithPath:path];
            UIActivityViewController *share = [[UIActivityViewController alloc]
                initWithActivityItems:@[fileURL] applicationActivities:nil];
            share.completionWithItemsHandler = ^(NSString *type, BOOL completed, NSArray *returned, NSError *e) {
                [[NSFileManager defaultManager] removeItemAtPath:fileURL.path error:nil];
                SparksLog(@"分享结束,更新包已删除");
            };
            UIViewController *top = [s topVC];
            if (top) {
                share.popoverPresentationController.sourceView = top.view;
                [top presentViewController:share animated:YES completion:nil];
            }
        });
    }];
    [task resume];
}

#pragma mark - 备份/恢复

- (void)exportBackup {
    NSString *json = [[SparksConfig shared] exportBackupJSON];
    if (!json.length) {
        SparksLog(@"⚠️ 备份导出失败");
        return;
    }
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"yyyyMMdd-HHmmss"];
    NSString *path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"sparks-backup-%@.json", [df stringFromDate:[NSDate date]]]];
    if (![[json dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES]) {
        SparksLog(@"⚠️ 备份文件写入失败");
        return;
    }
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[fileURL] applicationActivities:nil];
    share.completionWithItemsHandler = ^(NSString *type, BOOL completed, NSArray *returned, NSError *e) {
        [[NSFileManager defaultManager] removeItemAtPath:fileURL.path error:nil];
        SparksLog(@"备份分享结束,临时文件已删除");
    };
    UIViewController *top = [self topVC];
    if (top) {
        share.popoverPresentationController.sourceView = top.view;
        [top presentViewController:share animated:YES completion:nil];
    }
}

- (void)importBackup {
    __weak typeof(self) ws = self;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"恢复配置"
                                                                message:@"粘贴备份 JSON"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"{\"sparks....\":...}";
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"恢复" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *json = ac.textFields.firstObject.text;
        typeof(self) s = ws;
        if (!s) return;
        if ([[SparksConfig shared] importBackupJSON:json]) {
            SparksLog(@"✅ 配置已恢复,重载界面");
            [s refreshChrome];
            [s applyBallSize];
            [s applyPanelBackground];
            [s showToast:@"✅ 配置已恢复"];
        } else {
            SparksLog(@"⚠️ 恢复失败:JSON 解析不通过");
            [s showToast:@"❌ 恢复失败,看日志"];
        }
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *top = [self topVC];
    if (top) [top presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 目标操作

// 行点击:揭示态先收回;否则进入该目标的单独设置
- (void)tapTargetFromGesture:(UITapGestureRecognizer *)g {
    NSDictionary *t = objc_getAssociatedObject(g.view, "target");
    if (![t isKindOfClass:[NSDictionary class]]) return;
    UIView *content = objc_getAssociatedObject(g.view, "content");
    if (content && content.transform.tx != 0) {
        [self spAnimateRowReveal:g.view open:NO];
        return;
    }
    self.detailKey = SpTargetKeyOf(t);
    [self scheduleRebuild];
}

// 左滑:滑出红色删除按钮(带动画)
- (void)swipeDeleteTargetFromGesture:(UISwipeGestureRecognizer *)g {
    [self spAnimateRowReveal:g.view open:YES];
}

// 右滑:收回
- (void)swipeCloseTargetFromGesture:(UISwipeGestureRecognizer *)g {
    [self spAnimateRowReveal:g.view open:NO];
}

- (void)spAnimateRowReveal:(UIView *)row open:(BOOL)open {
    UIView *content = objc_getAssociatedObject(row, "content");
    UIControl *delBtn = objc_getAssociatedObject(row, "delbtn");
    if (!content || !delBtn) return;
    [UIView animateWithDuration:0.28 delay:0
         usingSpringWithDamping:0.82 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        content.transform = open ? CGAffineTransformMakeTranslation(-80, 0) : CGAffineTransformIdentity;
        delBtn.transform = open ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(80, 0);
    } completion:nil];
}

// 删除按钮:执行删除(揭示动作已是明确意图,不再二次弹窗)
- (void)targetDeleteConfirmFromSender:(UIControl *)sender {
    NSDictionary *t = objc_getAssociatedObject(sender, "target");
    if (![t isKindOfClass:[NSDictionary class]]) return;
    SparksConfig *cfg = [SparksConfig shared];
    NSString *key = SpTargetKeyOf(t);
    for (NSDictionary *old in [cfg.targets copy]) {
        if ([SpTargetKeyOf(old) isEqualToString:key]) {
            [cfg.targets removeObject:old];
            break;
        }
    }
    [cfg save];
    SparksLog(@"已删除目标:%@", SpTargetDisplayName(t));
    [self showToast:[NSString stringWithFormat:@"已删除 %@", SpTargetDisplayName(t)]];
    [self scheduleRebuild];
}

- (void)addTargetFromGesture:(UITapGestureRecognizer *)g {
    NSDictionary *t = objc_getAssociatedObject(g.view, "target");
    if (![t isKindOfClass:[NSDictionary class]]) return;
    SparksConfig *cfg = [SparksConfig shared];
    [cfg.targets addObject:@{@"key": SpTargetKeyOf(t),
                             @"type": SpTargetIsGroupOf(t) ? @"group" : @"single",
                             @"cid": t[@"cid"] ?: @"",
                             @"name": t[@"name"] ?: @"",
                             @"secUid": t[@"secUid"] ?: @""}];
    [cfg save];
    SparksLog(@"已添加目标:%@", t[@"name"] ?: SpTargetKeyOf(t));
    [self rebuildContent];
}

- (void)runSingleTarget:(NSDictionary *)target {
    // 并发保护:上一轮单发还在跑(含多轮条数)时不叠加,避免 targets 备份/恢复竞态
    if ([SparksEngine shared].running) {
        [self showToast:@"上一轮发送还在执行,稍等几秒再试"];
        return;
    }
    SparksConfig *cfg = [SparksConfig shared];
    NSArray *backup = [cfg.targets copy];
    cfg.targets = [NSMutableArray arrayWithObject:target];
    // 恢复时长按该目标每日条数放大(每多一条多留 45s)
    NSInteger dc = [target[@"dcount"] integerValue];
    if (dc < 1) dc = 1;
    double wait = 45.0 + (double)(dc - 1) * 45.0;
    __weak typeof(self) ws = self;
    [[SparksEngine shared] runDailyNow:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) s = ws;
        if (!s) return;
        SparksConfig *c = [SparksConfig shared];
        if (c.targets.count == 1 && [SpTargetKeyOf(c.targets[0]) isEqualToString:SpTargetKeyOf(target)]) {
            c.targets = [backup mutableCopy];
            [c save];
        }
    });
}

// 弹窗宿主:优先插件自己窗口的 rootVC。面板窗口层级高于宿主 App,
// 呈现在宿主窗口的弹窗会被本窗口盖住、触摸还会被背景捕获层吞掉(表现为"点了没反应/面板被关")
- (UIViewController *)topVC {
    UIViewController *vc = self.panelWindow.rootViewController;
    if (!vc) vc = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

@end

