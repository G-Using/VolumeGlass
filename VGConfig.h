#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

extern NSString *const VGDomain;          // com.shiyi.volumeglass
extern NSString *const VGChangedNotification;

BOOL    VGEnabled(void);                  // 总开关，默认 YES
BOOL    VGRimEnabled(void);               // 玻璃描边，默认 YES
BOOL    VGExtraBlur(void);                // 额外加一层模糊，默认 NO
BOOL    VGApplyToBrightness(void);        // 亮度 HUD 也应用，默认 NO
BOOL    VGDebugEnabled(void);             // 日志，默认 NO
BOOL    VGAutoCapsule(void);              // 圆角自动取 min(宽,高)/2，默认 YES
BOOL    VGSlideIn(void);                  // 从侧面滑入的动画，默认 YES

CGFloat VGRadius(void);                   // 圆角，默认 26，范围 0~60
CGFloat VGTintAlpha(void);                // 玻璃底色不透明度，默认 0.12，0~0.6
NSInteger VGLevelUp(void);                // 从 HUD 根视图向上找几层，默认 1，0~4

// 高级逃生口：手动指定要着色的类名 / 类名匹配不上时的兜底
NSString *VGClassOverride(void);

void    VGLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

#ifdef __cplusplus
}
#endif
