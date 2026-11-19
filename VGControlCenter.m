#import "VGControlCenter.h"
#import "VGConfig.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <dlfcn.h>

// CC uses a different slider from the side-button HUD. Do not decorate its
// controller/root view: that would clip the labels and expanded-module buttons.
@interface VGCCSliderState : NSObject
@property (nonatomic) BOOL applying;
@property (nonatomic) BOOL applied;
@property (nonatomic) BOOL hasNativeRadius;
@property (nonatomic) NSUInteger layoutDepth;
@property (nonatomic) NSUInteger radiusDepth;
@property (nonatomic) CGFloat nativeRadius;
@property (nonatomic) CGFloat originalLayerRadius;
@property (nonatomic) BOOL originalMasks;
@property (nonatomic, copy) NSString *originalCurve;
@end
@implementation VGCCSliderState
@end

static const void *VGCCStateKey = &VGCCStateKey;
static NSHashTable<UIView *> *VGCCSliders;
static NSMutableSet<NSString *> *VGCCInstalledClasses;

static VGCCSliderState *VGCCState(UIView *slider) {
    VGCCSliderState *state = objc_getAssociatedObject(slider, VGCCStateKey);
    if (!state) {
        state = [VGCCSliderState new];
        objc_setAssociatedObject(slider, VGCCStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [VGCCSliders addObject:slider];
    }
    return state;
}

// These fields belong to the module controllers on iOS 15/16, not to
// CCUIContinuousSliderView. Validate the runtime type before reading a BOOL.
static BOOL VGCCExpandedFlag(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) return NO;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || (strcmp(type, @encode(BOOL)) != 0 && strcmp(type, "B") != 0 && strcmp(type, "c") != 0)) return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    if (offset < 0 || (size_t)offset + sizeof(BOOL) > class_getInstanceSize(object_getClass(object))) return NO;
    BOOL expanded = NO;
    memcpy(&expanded, (const uint8_t *)(__bridge const void *)object + offset, sizeof(expanded));
    return expanded;
}

static BOOL VGCCIsKind(id object, const char *name) {
    Class cls = objc_getClass(name);
    return cls && [object isKindOfClass:cls];
}

static BOOL VGCCIsExpanded(UIView *slider) {
    for (UIResponder *r = slider; r; r = r.nextResponder) {
        if (VGCCIsKind(r, "MRUVolumeView")) {
            SEL getter = NSSelectorFromString(@"isExpanded");
            return [r respondsToSelector:getter] && ((BOOL (*)(id, SEL))objc_msgSend)(r, getter);
        }
        if (VGCCIsKind(r, "CCUIDisplayModuleViewController")) return VGCCExpandedFlag(r, "_expanded");
        if (VGCCIsKind(r, "MediaControlsVolumeViewController")) return VGCCExpandedFlag(r, "_isExpanded");
    }
    return NO;
}

static CGFloat VGCCRadius(UIView *slider) {
    CGSize size = slider.bounds.size;
    CGFloat half = MIN(size.width, size.height) * 0.5;
    if (half <= 0.5) return 0;
    CGFloat radius = VGAutoCapsule() ? half * VGCornerPercent() / 100.0 : VGRadius();
    return MAX(0, MIN(radius, half - 0.5));
}

static void VGCCApply(UIView *slider) {
    VGCCSliderState *state = VGCCState(slider);
    if (state.applying || state.layoutDepth || state.radiusDepth) return;
    SEL getter = NSSelectorFromString(@"continuousSliderCornerRadius");
    SEL setter = NSSelectorFromString(@"setContinuousSliderCornerRadius:");
    if (![slider respondsToSelector:getter] || ![slider respondsToSelector:setter]) return;
    state.applying = YES;
    BOOL active = VGEnabled() && (VGAutoCapsule() || VGRadius() > 0.5) && VGCCIsExpanded(slider);
    CGFloat radius = active ? VGCCRadius(slider) : 0;
    CALayer *layer = slider.layer;
    if (!active || radius <= 0) {
        if (state.applied) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            layer.cornerRadius = state.originalLayerRadius;
            layer.cornerCurve = state.originalCurve;
            layer.masksToBounds = state.originalMasks;
            // Restore our outer clip BEFORE the native setter reconfigures it.
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(slider, setter, state.nativeRadius);
            [CATransaction commit];
            state.applied = NO;
        }
        state.applying = NO;
        return;
    }
    if (!state.applied) {
        // Snapshot before calling any custom-radius setter, never afterwards.
        state.originalLayerRadius = layer.cornerRadius;
        state.originalCurve = layer.cornerCurve ?: kCACornerCurveCircular;
        state.originalMasks = layer.masksToBounds;
        if (!state.hasNativeRadius) {
            state.nativeRadius = ((CGFloat (*)(id, SEL))objc_msgSend)(slider, getter);
            state.hasNativeRadius = YES;
        }
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGFloat current = ((CGFloat (*)(id, SEL))objc_msgSend)(slider, getter);
    if (current < radius - 0.01 || current > radius + 0.01)
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(slider, setter, radius);
    // Clip the actual slider only. Never round the partial-value fill itself,
    // its clipping view, sibling materials, or the controller's full-screen view.
    layer.cornerRadius = radius;
    layer.cornerCurve = radius >= MIN(slider.bounds.size.width, slider.bounds.size.height) * 0.5 - 1 ? kCACornerCurveCircular : kCACornerCurveContinuous;
    layer.masksToBounds = YES;
    [CATransaction commit];
    state.applied = YES;
    state.applying = NO;
}

static BOOL VGCCHasMethod(Class cls, SEL selector) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        unsigned count = 0;
        Method *methods = class_copyMethodList(c, &count);
        BOOL found = NO;
        for (unsigned i = 0; i < count; i++) {
            if (sel_isEqual(method_getName(methods[i]), selector)) { found = YES; break; }
        }
        free(methods);
        if (found) return YES;
    }
    return NO;
}

static void VGCCImageLoaded(const struct mach_header *header, intptr_t slide) {
    Dl_info info = {0};
    if (!dladdr(header, &info) || !info.dli_fname) return;
    if (!strstr(info.dli_fname, "/ControlCenterUIKit.framework/") &&
        !strstr(info.dli_fname, "/MediaControls.framework/")) return;
    // Loader callbacks must not create UIKit objects or install hooks in-lock.
    dispatch_async(dispatch_get_main_queue(), ^{ VGInstallControlCenterHooks(); });
}

void VGInstallControlCenterHooks(void) {
    static BOOL observingImages = NO;
    if (!observingImages) {
        observingImages = YES;
        _dyld_register_func_for_add_image(VGCCImageLoaded);
    }
    if (!VGCCSliders) VGCCSliders = [NSHashTable weakObjectsHashTable];
    if (!VGCCInstalledClasses) VGCCInstalledClasses = [NSMutableSet set];
    // MRU overrides both methods on iOS 16; bind a distinct next IMP at each
    // installation and apply only after the outermost subclass/super layout.
    for (NSString *name in @[@"CCUIContinuousSliderView", @"MRUContinuousSliderView"]) {
        if ([VGCCInstalledClasses containsObject:name]) continue;
        Class cls = objc_getClass(name.UTF8String);
        SEL layout = @selector(layoutSubviews);
        SEL radius = NSSelectorFromString(@"setContinuousSliderCornerRadius:");
        if (!cls || !VGCCHasMethod(cls, layout) || !VGCCHasMethod(cls, radius)) continue;
        __block IMP nextLayout = NULL;
        IMP layoutHook = imp_implementationWithBlock(^(UIView *slider) {
            VGCCSliderState *state = VGCCState(slider);
            state.layoutDepth++;
            ((void (*)(id, SEL))nextLayout)(slider, layout);
            state.layoutDepth--;
            if (!state.layoutDepth) VGCCApply(slider);
        });
        __block IMP nextRadius = NULL;
        IMP radiusHook = imp_implementationWithBlock(^(UIView *slider, CGFloat value) {
            VGCCSliderState *state = VGCCState(slider);
            if (state.applying) {
                ((void (*)(id, SEL, CGFloat))nextRadius)(slider, radius, value);
                return;
            }
            if (!state.radiusDepth) { state.nativeRadius = value; state.hasNativeRadius = YES; }
            state.radiusDepth++;
            ((void (*)(id, SEL, CGFloat))nextRadius)(slider, radius, value);
            state.radiusDepth--;
            if (!state.radiusDepth) VGCCApply(slider);
        });
        MSHookMessageEx(cls, radius, radiusHook, &nextRadius);
        MSHookMessageEx(cls, layout, layoutHook, &nextLayout);
        [VGCCInstalledClasses addObject:name];
    }
}

void VGRefreshControlCenter(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ VGRefreshControlCenter(); });
        return;
    }
    VGInstallControlCenterHooks();
    for (UIView *slider in VGCCSliders.allObjects) {
        VGCCApply(slider);
        [slider setNeedsLayout];
    }
}
