//
//  SparksPanel.h
//  悬浮球 + 配置面板
//
#import "SparksConfig.h"

@interface SparksPanel : NSObject

+ (instancetype)shared;

/// App 启动完成后调用
- (void)setup;

/// 抖音设置页导航栏入口按钮回调(Tweak.x 经 action 调)
- (void)spOpenFromSettings;

@end
