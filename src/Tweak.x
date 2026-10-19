//
//  Tweak.x
//  抖音AI续火花助手 —— hook 入口
//
//  目标:抖音 40.7.0  (com.ss.iphone.ugc.Aweme, CFBundleVersion 407019)
//  本文件里每一个类/方法名都已对 40.7.0 的 AwemeCore.framework/AwemeCore
//  ObjC 元数据逐条复核(证据表:docs/40.7.0-verify.md,可复跑:tools/verify_ipa.py)。
//
//  | 类 | 方法 | 用途 |
//  | AWEIMMessageListViewModel                | setConversation:                                | 会话绑定(uid/cid/昵称/secUid) |
//  | AWEIMMessageListComponentCenter          | addComponent:/addComponents:/setComponents:     | 发送组件注册(40.7 主路径) |
//  | AWEIMMessageListSendMessageComponent     | componentDidMounted: / setDataService:          | 组件挂载生命周期 |
//  | AWEIMMessageListSendMessageComponent     | sendMessage:mentionUsers:customToast:enterFrom: | 文本发送终点(捕获模板) |
//  | AWEIMSendAttachmentController            | sendAttachmentMsgWithContext:completion:        | 图片/GIF/语音发送(媒体校准+自动直发) |
//  | AWEGeneralSettingViewController          | viewDidLoad                                     | 设置页入口(自有实现) |
//  | AWESettingsTableViewController           | viewDidAppear:                                  | 设置首页入口(DUX 导航栏,自有实现) |
//
//  ⚠️ 40.7.0 复核结论(不要改回去):
//   1) AWEIMMessageListSendMessageComponent **不实现 -init**(method list 里没有,
//      继承自超类)。对未实现的方法做 %hook,替换会落到超类的 Method 上 ——
//      等于 hook 全 App 的 init,并把任意对象当成发送组件塞进引擎,后续调用必崩。
//      故删除 -init 钩子;组件捕获由「组件中心 addComponent:/setComponents:」+
//      「componentDidMounted: / setDataService:」+「VM 组件中心兜底」三条路覆盖。
//   2) AWESettingPageBaseController 在 40.7.0 **不实现 viewDidLoad**,同理不能直接
//      hook;改为运行期用 class_copyMethodList 判定"自有实现"后再 %init 该钩子组。
//
#import "SparksConfig.h"
#import "SparksEngine.h"
#import "SparksPanel.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 运行期能力判定

/// 仅当 cls 的**自身** method list 里存在 sel 时才返回 YES。
/// 用于避免 hook 到继承来的实现(那会把补丁打到超类,影响全 App)。
static BOOL SparksClassImplements(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    BOOL found = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { found = YES; break; }
    }
    if (list) free(list);
    return found;
}

static void SparksLogVersions(void) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *shortV = info[@"CFBundleShortVersionString"];
    NSString *build  = info[@"CFBundleVersion"];
    NSLog(@"[Sparks] 抖音版本 %@ (%@) —— 插件按 40.7.0 逆向,启动自检:", shortV, build);
    NSArray<NSArray<NSString *> *> *probe = @[
        @[@"AWEIMMessageListViewModel",            @"setConversation:"],
        @[@"AWEIMMessageListComponentCenter",      @"addComponent:"],
        @[@"AWEIMMessageListSendMessageComponent", @"sendMessage:mentionUsers:customToast:enterFrom:"],
        @[@"AWEIMMessageListSendMessageComponent", @"componentDidMounted:"],
        @[@"AWEIMSendAttachmentController",        @"sendAttachmentMsgWithContext:completion:"],
    ];
    for (NSArray<NSString *> *p in probe) {
        Class c = NSClassFromString(p[0]);
        SEL s = NSSelectorFromString(p[1]);
        NSLog(@"[Sparks]   %@ %@.%@", SparksClassImplements(c, s) ? @"OK" : @"MISS", p[0], p[1]);
    }
}

#pragma mark - 会话追踪

%hook AWEIMMessageListViewModel

- (void)setConversation:(id)conversation {
    %orig;
    // 参数是会话模型;VM 本体(self)才持有 componentCenter,两个都要传
    [[SparksEngine shared] noteConversation:conversation inVM:self];
}

%end

#pragma mark - 发送组件注册(40.7.0 主路径:组件中心)

%hook AWEIMMessageListComponentCenter

- (void)addComponent:(id)component {
    %orig;
    if ([component isKindOfClass:NSClassFromString(@"AWEIMMessageListSendMessageComponent")]) {
        [[SparksEngine shared] noteComponent:component];
    }
}

- (void)addComponents:(NSArray<id> *)components {
    %orig;
    for (id c in (NSArray *)components) {
        if ([c isKindOfClass:NSClassFromString(@"AWEIMMessageListSendMessageComponent")]) {
            [[SparksEngine shared] noteComponent:c];
        }
    }
}

- (void)setComponents:(NSArray<id> *)components {
    %orig;
    for (id c in (NSArray *)components) {
        if ([c isKindOfClass:NSClassFromString(@"AWEIMMessageListSendMessageComponent")]) {
            [[SparksEngine shared] noteComponent:c];
        }
    }
}

%end

#pragma mark - 发送组件

%hook AWEIMMessageListSendMessageComponent

- (void)componentDidMounted:(id)arg {
    %orig;
    [[SparksEngine shared] noteComponent:self];   // 40.7.0 挂载生命周期(自有实现)
}

- (void)setDataService:(id)dataService {
    %orig;
    [[SparksEngine shared] noteComponent:self];   // 40.6.0 老路保留(40.7.0 仍实现)
}

- (void)sendMessage:(id)context
      mentionUsers:(id)mentionUsers
       customToast:(id)customToast
          enterFrom:(NSString *)enterFrom {
    [[SparksEngine shared] observeSendWithContext:context component:self];
    %orig;
}

%end

#pragma mark - 附件(图片/GIF/语音)发送:校准捕获 + 自动直发

%hook AWEIMSendAttachmentController

- (void)sendAttachmentMsgWithContext:(id)context completion:(id)completion {
    [[SparksEngine shared] observeAttachmentSend:context];
    %orig;
}

%end

#pragma mark - 设置页入口
// 40.6.0 两套体系:AWESettingPageBaseController 家族 + AWEGeneralSettingViewController。
// 40.7.0 实测:设置首页是 AWESettingsTableViewController,走 DUX 自定义导航栏
// (shouldUseDUXNavigationBar 返回 YES),navigationItem.rightBarButtonItem 不渲染。
// 因此:AWEGeneralSettingViewController 仍走系统右键;设置首页额外注入悬浮火焰按钮兜底。

static void SparksAddSettingEntry(UIViewController *vc) {
    @try {
        if (!vc.navigationItem) return;
        if (vc.navigationItem.rightBarButtonItem) return;                       // 已有右键不动
        UINavigationController *nav = vc.navigationController;
        if (nav && nav.viewControllers.count > 1) return;                       // 子页不加,只在设置首页
        UIBarButtonItem *item = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"flame.fill"]
                    style:UIBarButtonItemStylePlain
                   target:[SparksPanel shared]
                   action:@selector(spOpenFromSettings)];
        item.tintColor = [UIColor colorWithRed:1.0 green:0.48 blue:0.18 alpha:1.0];
        vc.navigationItem.rightBarButtonItem = item;
    } @catch (NSException *e) {
        NSLog(@"[Sparks] 设置页入口注入失败:%@", e);
    }
}

static void SparksAddFloatingEntry(UIViewController *vc) {
    @try {
        if (!vc.isViewLoaded || !vc.view.window) return;
        if ([vc.view viewWithTag:209527]) return;                     // 防重复注入
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.tag = 209527;
        [btn setImage:[UIImage systemImageNamed:@"flame.fill"] forState:UIControlStateNormal];
        btn.tintColor = [UIColor colorWithRed:1.0 green:0.48 blue:0.18 alpha:1.0];
        btn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.32];
        btn.layer.cornerRadius = 17;
        btn.layer.cornerCurve = kCACornerCurveContinuous;
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        [vc.view addSubview:btn];
        [btn.widthAnchor constraintEqualToConstant:34].active = YES;
        [btn.heightAnchor constraintEqualToConstant:34].active = YES;
        [btn.trailingAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.trailingAnchor constant:-16].active = YES;
        [btn.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-20].active = YES;
        [btn addTarget:[SparksPanel shared] action:@selector(spOpenFromSettings)
      forControlEvents:UIControlEventTouchUpInside];
    } @catch (NSException *e) {
        NSLog(@"[Sparks] 悬浮入口注入失败:%@", e);
    }
}

%hook AWESettingsTableViewController

- (void)viewDidAppear:(BOOL)a {
    %orig;
    SparksAddSettingEntry((UIViewController *)self);
    SparksAddFloatingEntry((UIViewController *)self);
}

%end

// 这两个类是否真的自己实现 viewDidLoad 随版本变化:40.7.0 里
// AWEGeneralSettingViewController -> 有 / AWESettingPageBaseController -> 没有。
// 用钩子组做到「有实现才装钩子」:既保住老版本入口,又不会把补丁打到超类上。
%group SparksGeneralSettingHooks
%hook AWEGeneralSettingViewController
- (void)viewDidLoad {
    %orig;
    SparksAddSettingEntry((UIViewController *)self);
}
%end
%end

%group SparksSettingPageBaseHooks
%hook AWESettingPageBaseController
- (void)viewDidLoad {
    %orig;
    SparksAddSettingEntry((UIViewController *)self);
}
%end
%end

#pragma mark - 启动

static void SparksInstallSettingHooks(void) {
    if (SparksClassImplements(objc_getClass("AWEGeneralSettingViewController"), @selector(viewDidLoad))) {
        %init(SparksGeneralSettingHooks);
    } else {
        NSLog(@"[Sparks] AWEGeneralSettingViewController 无自身 viewDidLoad,跳过该入口");
    }
    if (SparksClassImplements(objc_getClass("AWESettingPageBaseController"), @selector(viewDidLoad))) {
        %init(SparksSettingPageBaseHooks);
    } else {
        NSLog(@"[Sparks] AWESettingPageBaseController 无自身 viewDidLoad(40.7.0 已如此),跳过该入口");
    }
}

static void SparksInit(void) {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (![bundleID isEqualToString:@"com.ss.iphone.ugc.Aweme"]) return;

        SparksLogVersions();
        SparksInstallSettingHooks();

        [[SparksConfig shared] reload];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil queue:nil
                                                     usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[SparksEngine shared] start];
                [[SparksPanel shared] setup];
            });
        }];
    }
}

%ctor {
    // 用了 %group 之后,未分组的钩子不再自动装配,必须显式初始化,
    // 否则 Logos 直接报 "non-initialized hook group: _ungrouped"。
    %init(_ungrouped);
    SparksInit();
}
