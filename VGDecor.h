#import <UIKit/UIKit.h>

// 给 HUD 容器套上"圆角 + 玻璃"
void VGDecorateHUDView(UIView *host);

// 设置变更后立刻重刷（对当前可见的 HUD 生效）
void VGRefreshDecor(void);

// 关掉后还原原样
void VGTeardownHUDView(UIView *host);
