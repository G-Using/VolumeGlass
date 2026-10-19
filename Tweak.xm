#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import "VGConfig.h"
#import "VGDecor.h"

typedef void (*VGAppearIMP)(id, SEL, BOOL);
typedef void (*VGLayoutIMP)(id, SEL);

static NSMutableDictionary<NSString *, NSValue *> *gOriginals;

#pragma mark - 原实现查找（同一 SEL 可能被多个类 hook）

static IMP VGOriginal(id self, SEL sel) {
    Class c = object_getClass(self);
    NSString *selName = NSStringFromSelector(sel);
    while (c) {
        NSString *key = [NSString stringWithFormat:@"%@|%@", NSStringFromClass(c), selName];
        NSValue *v = gOriginals[key];
        if (v) return (IMP)v.pointerValue;
        c = class_getSuperclass(c);
    }
    return NULL;
}

static void VGInstall(Class cls, SEL sel, IMP replacement) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        VGLog(@"%@ has no %@, skip", NSStringFromClass(cls), NSStringFromSelector(sel));
        return;
    }
    IMP orig = NULL;
    MSHookMessageEx(cls, sel, replacement, &orig);
    if (orig) {
        NSString *key = [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
        gOriginals[key] = [NSValue valueWithPointer:(void *)orig];
        VGLog(@"hooked %@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
    }
}

#pragma mark - 找要着色的那层

static UIView *VGFindHost(UIView *root, NSInteger extra) {
    if (!root) return nil;

    NSString *want = VGClassOverride();
    if (want.length) {
        for (UIView *v = root; v; v = v.superview) {
            if ([NSStringFromClass([v class]) isEqualToString:want]) return v;
        }
        VGLog(@"ClassOverride=%@ not found, fallback to LevelUp", want);
    }

    UIView *v = root;
    NSInteger steps = VGLevelUp() + extra;
    for (NSInteger i = 0; i < steps && v.superview; i++) v = v.superview;
    return v;
}

#pragma mark - 音量 / 亮度判定

static void VGScanNames(UIView *v, int depth, BOOL *vol, BOOL *bri) {
    if (!v || depth > 3) return;
    NSString *cn = NSStringFromClass([v class]);
    if ([cn containsString:@"Volume"]) *vol = YES;
    if ([cn containsString:@"Brightness"]) *bri = YES;
    for (UIView *s in v.subviews) VGScanNames(s, depth + 1, vol, bri);
}

static BOOL VGShouldApply(UIViewController *vc) {
    BOOL vol = NO, bri = NO;

    NSString *cn = NSStringFromClass([vc class]);
    if ([cn containsString:@"Volume"]) vol = YES;
    if ([cn containsString:@"Brightness"]) bri = YES;

    if (vc.isViewLoaded) VGScanNames(vc.view, 0, &vol, &bri);

    for (UIViewController *child in vc.childViewControllers) {
        NSString *ccn = NSStringFromClass([child class]);
        if ([ccn containsString:@"Volume"]) vol = YES;
        if ([ccn containsString:@"Brightness"]) bri = YES;
        if (child.isViewLoaded) VGScanNames(child.view, 0, &vol, &bri);
    }

    if (vol) return YES;
    if (bri) return VGApplyToBrightness();
    return YES;   // 判定不出来时默认按音量处理
}

static void VGDump(UIView *v, int depth) {
    if (!v || depth > 3) return;
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"  "];
    VGLog(@"%@%@ %@", pad, NSStringFromClass([v class]), NSStringFromCGRect(v.frame));
    for (UIView *s in v.subviews) VGDump(s, depth + 1);
}

#pragma mark - Hook 回调

static void vg_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    IMP orig = VGOriginal(self, _cmd);
    if (orig) ((VGAppearIMP)orig)(self, _cmd, animated);

    if (!VGEnabled()) return;
    UIViewController *vc = (UIViewController *)self;
    if (!VGShouldApply(vc)) {
        VGLog(@"%@ is brightness HUD, skip", NSStringFromClass([vc class]));
        return;
    }
    UIView *root = [vc view];
    if (!root) return;
    VGDump(root, 0);
    VGDecorateHUDView(VGFindHost(root, 0));
}

static void vg_viewDidLayout(id self, SEL _cmd) {
    IMP orig = VGOriginal(self, _cmd);
    if (orig) ((VGLayoutIMP)orig)(self, _cmd);

    if (!VGEnabled()) return;
    UIViewController *vc = (UIViewController *)self;
    if (!vc.isViewLoaded) return;
    if (!VGShouldApply(vc)) return;
    UIView *host = VGFindHost(vc.view, 0);
    if (host && host.bounds.size.width > 0) VGDecorateHUDView(host);
}

// 控制中心里也有一堆 SBElasticSliderView，只处理挂在 HUD 上的那些
static BOOL VGInsideHUD(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([NSStringFromClass([v class]) containsString:@"HUD"]) return YES;
    }
    return NO;
}

static void vg_sliderLayout(id self, SEL _cmd) {
    IMP orig = VGOriginal(self, _cmd);
    if (orig) ((VGLayoutIMP)orig)(self, _cmd);

    if (!VGEnabled()) return;
    UIView *slider = (UIView *)self;
    if (!VGInsideHUD(slider)) return;
    UIView *host = VGFindHost(slider, 1);
    if (host) VGDecorateHUDView(host);
}

#pragma mark - 设置变更

static void VGOnChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                        const void *object, CFDictionaryRef userInfo) {
    VGRefreshDecor();
}

__attribute__((constructor)) static void VGInit(void) {
    gOriginals = [NSMutableDictionary dictionary];

    Class hud = objc_getClass("SBElasticHUDViewController");
    if (hud) {
        VGInstall(hud, @selector(viewWillAppear:), (IMP)vg_viewWillAppear);
        VGInstall(hud, @selector(viewDidLayoutSubviews), (IMP)vg_viewDidLayout);
    } else {
        VGLog(@"no SBElasticHUDViewController, use slider fallback");
    }

    NSArray *fallbacks = @[@"SBElasticSliderView", @"SBElasticVolumeSliderView", @"_CCUIBaseSliderContentView"];
    for (NSString *name in fallbacks) {
        Class c = objc_getClass(name.UTF8String);
        if (c) VGInstall(c, @selector(layoutSubviews), (IMP)vg_sliderLayout);
    }

    NSString *override = VGClassOverride();
    if (override.length) {
        Class c = objc_getClass(override.UTF8String);
        if (c) VGInstall(c, @selector(layoutSubviews), (IMP)vg_sliderLayout);
        else VGLog(@"ClassOverride %@ not exist", override);
    }

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    VGOnChanged,
                                    (__bridge CFStringRef)VGChangedNotification,
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    VGLog(@"VolumeGlass 0.2.4 loaded");
}
