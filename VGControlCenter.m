#import "VGControlCenter.h"
#import "VGConfig.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <math.h>
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
@property (nonatomic, strong) NSMutableArray *surfaceSnapshots;
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
        state.surfaceSnapshots = [NSMutableArray array];
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
        if (VGCCIsKind(r, "CCUIDisplayBackgroundViewController")) {
            // These controls exist only on the expanded backdrop, not the small tile.
            SEL white = NSSelectorFromString(@"whitePointSliderView");
            SEL night = NSSelectorFromString(@"nightShiftSliderView");
            if (([r respondsToSelector:white] && ((id (*)(id, SEL))objc_msgSend)(r, white) == slider) ||
                ([r respondsToSelector:night] && ((id (*)(id, SEL))objc_msgSend)(r, night) == slider)) return YES;
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
    radius = MAX(0, MIN(radius, half - 0.5));
    // A full capsule can bite into the native low-value fill even when we no
    // longer round that fill ourselves. Ease back towards Apple's own radius
    // when there is insufficient filled height for the larger bottom corners.
    SEL nativeGetter = NSSelectorFromString(@"continuousSliderCornerRadius");
    SEL valueGetter = NSSelectorFromString(@"value");
    SEL lengthGetter = NSSelectorFromString(@"sliderLengthForValue:");
    if (size.height > size.width && [slider respondsToSelector:nativeGetter] &&
        [slider respondsToSelector:valueGetter] && [slider respondsToSelector:lengthGetter]) {
        CGFloat native = ((CGFloat (*)(id, SEL))objc_msgSend)(slider, nativeGetter);
        float value = ((float (*)(id, SEL))objc_msgSend)(slider, valueGetter);
        if (isfinite(native) && native > 0 && isfinite(value) && value >= 0 && value <= 1) {
            CGFloat length = ((CGFloat (*)(id, SEL, float))objc_msgSend)(slider, lengthGetter, value);
            if (isfinite(length) && length >= 0 && length <= size.height + 1)
                radius = MIN(radius, MAX(MIN(native, half-0.5), length * 0.5));
        }
    }
    return radius;
}

@interface VGCCSurfaceSnapshot : NSObject
@property (nonatomic, weak) UIView *view;
@property (nonatomic) CGFloat radius;
@property (nonatomic) CGFloat continuousRadius;
@property (nonatomic) BOOL hasContinuousRadius;
@property (nonatomic) BOOL masks;
@property (nonatomic) CGFloat borderWidth;
@property (nonatomic) float shadowOpacity;
@property (nonatomic) CGFloat shadowRadius;
@property (nonatomic, strong) UIBezierPath *shadowPath;
@property (nonatomic, copy) NSString *curve;
@end
@implementation VGCCSurfaceSnapshot
@end

static UIView *VGCCViewForSelector(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
    return [value isKindOfClass:UIView.class] ? value : nil;
}

static UIView *VGCCViewIvar(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    if (!type || type[0] != '@') return nil;
    id value = object_getIvar(object, ivar);
    return [value isKindOfClass:UIView.class] ? value : nil;
}

static BOOL VGCCSameOutline(UIView *view, UIView *slider) {
    if (!view || !view.window || view.window != slider.window) return NO;
    CGRect rect = [view convertRect:view.bounds toView:slider];
    CGRect target = slider.bounds;
    return fabs(rect.origin.x-target.origin.x) < 2 && fabs(rect.origin.y-target.origin.y) < 2 &&
        fabs(rect.size.width-target.size.width) < 2 && fabs(rect.size.height-target.size.height) < 2;
}

static BOOL VGCCIsMaterial(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return [name containsString:@"Material"] || [name containsString:@"Backdrop"] ||
        [name containsString:@"VisualEffect"];
}

static void VGCCCollectMaterials(UIView *root, UIView *slider, NSMutableOrderedSet<UIView *> *targets, unsigned depth) {
    if (depth > 3) return;
    if (VGCCIsMaterial(root) && VGCCSameOutline(root, slider)) [targets addObject:root];
    for (UIView *child in root.subviews) {
        if ([child isKindOfClass:UIControl.class]) continue;
        if (VGCCSameOutline(child, slider)) VGCCCollectMaterials(child, slider, targets, depth+1);
    }
}

static NSArray<UIView *> *VGCCSurfaces(UIView *slider) {
    NSMutableOrderedSet<UIView *> *targets = [NSMutableOrderedSet orderedSetWithObject:slider];
    // The native platter can be a sibling, not a child of the slider. Keeping
    // its old radius was the second contour visible behind the 0.4.3 capsule.
    UIView *parent = slider.superview;
    for (NSUInteger level = 0; parent && level < 4; level++, parent = parent.superview) {
        for (UIView *sibling in parent.subviews) {
            if (sibling == slider || !VGCCSameOutline(sibling, slider)) continue;
            if (VGCCIsMaterial(sibling)) VGCCCollectMaterials(sibling, slider, targets, 0);
            else if (sibling.class == UIView.class &&
                     (sibling.layer.borderWidth > 0 || sibling.layer.shadowOpacity > 0))
                [targets addObject:sibling];
        }
        if (VGCCSameOutline(parent, slider) &&
            (parent.class == UIView.class || VGCCIsKind(parent, "CCUIContentModuleContentContainerView")))
            [targets addObject:parent];
        if (VGCCIsKind(parent, "CCUIContentModuleContentContainerView")) {
            UIView *material = VGCCViewIvar(parent, "_moduleMaterialView");
            if (VGCCSameOutline(material, slider)) VGCCCollectMaterials(material, slider, targets, 0);
            break;
        }
        if (parent.bounds.size.width > slider.bounds.size.width * 3) break;
    }
    for (UIView *view in @[VGCCViewIvar(slider, "_backgroundView") ?: slider,
                            VGCCViewForSelector(slider, @"materialView") ?: slider]) {
        if (view != slider && VGCCSameOutline(view, slider)) {
            [targets addObject:view];
            VGCCCollectMaterials(view, slider, targets, 0);
        }
    }
    // BetterCCBrightness owns the two side sliders in the BACKGROUND controller.
    for (UIResponder *r = slider.nextResponder; r; r = r.nextResponder) {
        if (!VGCCIsKind(r, "CCUIDisplayBackgroundViewController")) continue;
        for (NSArray<NSString *> *pair in @[@[@"whitePointSliderView", @"whitePointMaterialView"],
                                           @[@"nightShiftSliderView", @"nightShiftMaterialView"]]) {
            if (VGCCViewForSelector(r, pair[0]) == slider) {
                UIView *material = VGCCViewForSelector(r, pair[1]);
                if (VGCCSameOutline(material, slider)) VGCCCollectMaterials(material, slider, targets, 0);
            }
        }
        break;
    }
    // Leave valueIndicatorClippingView and its moving fill untouched. Rounding
    // both a short fill and the tall track intersects two different capsules,
    // producing the pointed lens visible at low volume in 0.4.4.
    UIView *fill = VGCCViewForSelector(slider, @"valueIndicatorClippingView");
    if (fill) {
        for (UIView *view in [targets.array copy]) {
            if (view == fill || [view isDescendantOfView:fill]) [targets removeObject:view];
        }
    }
    return targets.array;
}

static void VGCCRoundSurface(UIView *view, CGFloat radius, NSMutableArray *snapshots) {
    CGFloat half = MIN(view.bounds.size.width, view.bounds.size.height) * 0.5;
    if (half <= 0.5) return;
    VGCCSurfaceSnapshot *snapshot = [VGCCSurfaceSnapshot new];
    snapshot.view = view;
    snapshot.radius = view.layer.cornerRadius;
    snapshot.curve = view.layer.cornerCurve ?: kCACornerCurveCircular;
    snapshot.masks = view.layer.masksToBounds;
    snapshot.borderWidth = view.layer.borderWidth;
    snapshot.shadowOpacity = view.layer.shadowOpacity;
    snapshot.shadowRadius = view.layer.shadowRadius;
    snapshot.shadowPath = view.layer.shadowPath ? [UIBezierPath bezierPathWithCGPath:view.layer.shadowPath] : nil;
    SEL getter = NSSelectorFromString(@"_continuousCornerRadius");
    SEL setter = NSSelectorFromString(@"_setContinuousCornerRadius:");
    snapshot.hasContinuousRadius = [view respondsToSelector:getter] && [view respondsToSelector:setter];
    if (snapshot.hasContinuousRadius) {
        snapshot.continuousRadius = ((CGFloat (*)(id, SEL))objc_msgSend)(view, getter);
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(view, setter, MIN(radius, half-0.5));
    }
    [snapshots addObject:snapshot];
    view.layer.cornerRadius = MIN(radius, half-0.5);
    view.layer.cornerCurve = kCACornerCurveCircular;
    view.layer.masksToBounds = YES;
    // Same fix used for the side HUD: remove the native shadow/border chrome,
    // not the material itself. Keep the backdrop, opacity, filters and fill.
    view.layer.shadowOpacity = 0;
    view.layer.shadowRadius = 0;
    view.layer.shadowPath = nil;
    view.layer.borderWidth = 0;
}

static void VGCCRestoreSurfaces(VGCCSliderState *state) {
    if (!state.applied) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (VGCCSurfaceSnapshot *snapshot in state.surfaceSnapshots) {
        UIView *view = snapshot.view;
        if (!view) continue;
        if (snapshot.hasContinuousRadius)
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(view, NSSelectorFromString(@"_setContinuousCornerRadius:"), snapshot.continuousRadius);
        view.layer.cornerRadius = snapshot.radius;
        view.layer.cornerCurve = snapshot.curve;
        view.layer.masksToBounds = snapshot.masks;
        view.layer.borderWidth = snapshot.borderWidth;
        view.layer.shadowOpacity = snapshot.shadowOpacity;
        view.layer.shadowRadius = snapshot.shadowRadius;
        view.layer.shadowPath = snapshot.shadowPath.CGPath;
    }
    [state.surfaceSnapshots removeAllObjects];
    state.applied = NO;
    [CATransaction commit];
}

static void VGCCApply(UIView *slider) {
    VGCCSliderState *state = VGCCState(slider);
    if (state.applying || state.layoutDepth || state.radiusDepth) return;
    state.applying = YES;
    VGCCRestoreSurfaces(state);
    BOOL active = VGEnabled() && (VGAutoCapsule() || VGRadius() > 0.5) && VGCCIsExpanded(slider);
    CGFloat radius = active ? VGCCRadius(slider) : 0;
    if (radius > 0) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        // Do not change the native slider-radius model: the module reassigns it
        // during layout. Synchronize the existing surfaces without adding layers.
        for (UIView *surface in VGCCSurfaces(slider))
            VGCCRoundSurface(surface, radius, state.surfaceSnapshots);
        state.applied = state.surfaceSnapshots.count > 0;
        [CATransaction commit];
    }
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
        !strstr(info.dli_fname, "/MediaControls.framework/") &&
        !strstr(info.dli_fname, "/DisplayModule.bundle/")) return;
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
            if (!state.layoutDepth && !state.applying) {
                state.applying = YES;
                VGCCRestoreSurfaces(state);
                state.applying = NO;
            }
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
            if (!state.radiusDepth) {
                state.applying = YES;
                VGCCRestoreSurfaces(state);
                state.applying = NO;
            }
            state.radiusDepth++;
            ((void (*)(id, SEL, CGFloat))nextRadius)(slider, radius, value);
            state.radiusDepth--;
            if (!state.radiusDepth) VGCCApply(slider);
        });
        MSHookMessageEx(cls, radius, radiusHook, &nextRadius);
        MSHookMessageEx(cls, layout, layoutHook, &nextLayout);
        [VGCCInstalledClasses addObject:name];
    }
    // The brightness extension assigns its sibling-material radius during the
    // controller layout. Reconcile only that controller's sliders afterwards.
    for (NSString *name in @[@"CCUIDisplayBackgroundViewController", @"CCUIDisplayModuleViewController", @"MRUVolumeViewController"]) {
        if ([VGCCInstalledClasses containsObject:name]) continue;
        Class cls = objc_getClass(name.UTF8String);
        SEL layout = @selector(viewDidLayoutSubviews);
        if (!cls || !VGCCHasMethod(cls, layout)) continue;
        __block IMP next = NULL;
        IMP hook = imp_implementationWithBlock(^(UIViewController *controller) {
            ((void (*)(id, SEL))next)(controller, layout);
            for (UIView *slider in VGCCSliders.allObjects) {
                for (UIResponder *r = slider.nextResponder; r; r = r.nextResponder) {
                    if (r != controller) continue;
                    VGCCApply(slider);
                    break;
                }
            }
        });
        MSHookMessageEx(cls, layout, hook, &next);
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
