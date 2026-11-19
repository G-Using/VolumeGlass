#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import "VGConfig.h"
#import "VGDecor.h"
#import "VGControlCenter.h"

typedef void (*VGAppearIMP)(id, SEL, BOOL);
typedef void (*VGLayoutIMP)(id, SEL);

static NSMutableSet<NSString *> *gVGInstalledHooks;

#pragma mark - 每个安装点独立保存 next IMP，父子类不会串用

static void VGInstall(Class cls, SEL sel, IMP replacement) {
    if (!cls) return;
    NSString *key = [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
    if ([gVGInstalledHooks containsObject:key]) return;
    Method method = NULL;
    for (Class c = cls; c && !method; c = class_getSuperclass(c)) {
        unsigned count = 0;
        Method *methods = class_copyMethodList(c, &count);
        for (unsigned i = 0; i < count; i++) {
            if (sel_isEqual(method_getName(methods[i]), sel)) { method = methods[i]; break; }
        }
        free(methods);
    }
    if (!method) return;
    unsigned args = method_getNumberOfArguments(method);
    __block IMP next = NULL;
    IMP wrapper = NULL;
    if (args == 2) {
        wrapper = imp_implementationWithBlock(^(id receiver) {
            if (next) ((VGLayoutIMP)next)(receiver, sel);
            ((VGLayoutIMP)replacement)(receiver, sel);
        });
    } else if (args == 3 && sel_isEqual(sel, @selector(viewWillAppear:))) {
        wrapper = imp_implementationWithBlock(^(id receiver, BOOL animated) {
            if (next) ((VGAppearIMP)next)(receiver, sel, animated);
            ((VGAppearIMP)replacement)(receiver, sel, animated);
        });
    }
    if (!wrapper) return;
    MSHookMessageEx(cls, sel, wrapper, &next);
    [gVGInstalledHooks addObject:key];
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
    if (!VGEnabled()) return;
    UIView *slider = (UIView *)self;
    if (!VGInsideHUD(slider)) return;
    UIView *host = VGFindHost(slider, 1);
    if (host) VGDecorateHUDView(host);
}

#pragma mark - 设置变更

static void VGOnChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                        const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VGRefreshDecor();
        VGRefreshControlCenter();
    });
}

__attribute__((constructor)) static void VGInit(void) {
    gVGInstalledHooks = [NSMutableSet set];

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

    dispatch_async(dispatch_get_main_queue(), ^{
        VGInstallControlCenterHooks();
    });
    VGLog(@"VolumeGlass 0.4.3 loaded");
}
