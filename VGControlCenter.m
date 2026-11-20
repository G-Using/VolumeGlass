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
@property (nonatomic) BOOL modelOverridden;
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
static const void *VGCCExpandedIntentKey = &VGCCExpandedIntentKey;
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
        NSNumber *intent = objc_getAssociatedObject(r, VGCCExpandedIntentKey);
        if (intent) return intent.boolValue;
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

// Use the same outline before and after expansion, so UIKit does not
// capture a compact rounded rectangle as the transition's starting shape.
static BOOL VGCCShouldRound(UIView *slider) {
    if (VGCCIsExpanded(slider)) return YES;
    BOOL target = NO;
    BOOL inModule = NO;
    for (UIResponder *r = slider.nextResponder; r; r = r.nextResponder) {
        if (VGCCIsKind(r, "CCUIDisplayModuleViewController") ||
            VGCCIsKind(r, "MRUVolumeViewController") ||
            VGCCIsKind(r, "MediaControlsVolumeViewController")) target = YES;
        if (VGCCIsKind(r, "CCUIContentModuleContentContainerView")) inModule = YES;
        if (target && inModule) return YES;
    }
    return NO;
}

static CGFloat VGCCRadius(UIView *slider) {
    CGSize size = slider.bounds.size;
    CGFloat half = MIN(size.width, size.height) * 0.5;
    if (half <= 0.5) return 0;
    CGFloat radius = VGAutoCapsule() ? half * VGCornerPercent() / 100.0 : VGRadius();
    // Fixed for a given slider size/settings; never derive track corners from value.
    return MAX(0, MIN(radius, half - 0.5));
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

// UIKit can bundle radius with position, bounds and opacity. Strip only
// the radius leaf, and keep the group's timing and other child animations.
static CAAnimation *VGCCWithoutRadiusAnimation(CAAnimation *animation) {
    if ([animation isKindOfClass:CAPropertyAnimation.class] &&
        [((CAPropertyAnimation *)animation).keyPath isEqualToString:@"cornerRadius"]) return nil;
    if (![animation isKindOfClass:CAAnimationGroup.class]) return animation;
    CAAnimationGroup *group = (CAAnimationGroup *)animation;
    NSMutableArray<CAAnimation *> *children = [NSMutableArray array];
    BOOL changed = NO;
    for (CAAnimation *child in group.animations) {
        CAAnimation *filtered = VGCCWithoutRadiusAnimation(child);
        if (filtered != child) changed = YES;
        if (filtered) [children addObject:filtered];
    }
    if (!changed) return group;
    CAAnimationGroup *filtered = [group copy];
    filtered.animations = children;
    return filtered;
}

static void VGCCRoundSurface(UIView *view, CGFloat radius, NSMutableArray *snapshots, BOOL clip) {
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
    for (NSString *key in view.layer.animationKeys) {
        CAAnimation *animation = [view.layer animationForKey:key];
        CAAnimation *filtered = VGCCWithoutRadiusAnimation(animation);
        if (filtered == animation) continue;
        if (filtered) [view.layer addAnimation:filtered forKey:key];
        else [view.layer removeAnimationForKey:key];
    }
    // Never add another clipping boundary over the native fill geometry.
    if (clip) view.layer.masksToBounds = YES;
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

// Caller holds state.applying so our setters/layout wrappers only call next IMP.
static void VGCCRestoreNativeModel(UIView *slider, VGCCSliderState *state) {
    VGCCRestoreSurfaces(state);
    if (!state.modelOverridden) return;
    state.modelOverridden = NO;
    ((void (*)(id, SEL, CGFloat))objc_msgSend)(slider,
        NSSelectorFromString(@"setContinuousSliderCornerRadius:"), state.nativeRadius);
}

static void VGCCApply(UIView *slider) {
    VGCCSliderState *state = VGCCState(slider);
    if (state.applying || state.layoutDepth || state.radiusDepth) return;
    SEL getter = NSSelectorFromString(@"continuousSliderCornerRadius");
    SEL setter = NSSelectorFromString(@"setContinuousSliderCornerRadius:");
    if (![slider respondsToSelector:getter] || ![slider respondsToSelector:setter]) return;
    state.applying = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    VGCCRestoreSurfaces(state);
    BOOL active = VGEnabled() && (VGAutoCapsule() || VGRadius() > 0.5) && VGCCShouldRound(slider);
    CGFloat radius = active ? VGCCRadius(slider) : 0;
    if (radius > 0) {
        if (!state.modelOverridden) {
            state.nativeRadius = ((CGFloat (*)(id, SEL))objc_msgSend)(slider, getter);
            state.hasNativeRadius = YES;
        }
        // The track radius is a layout INPUT, not just an outer layer style.
        // Let Apple's layout compute its native fill length and clipping using
        // the same fixed radius as the background, at every value including 0.
        CGFloat current = ((CGFloat (*)(id, SEL))objc_msgSend)(slider, getter);
        if (fabs(current-radius) > 0.01) {
            state.modelOverridden = YES;
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(slider, setter, radius);
            // Guarded synchronous native layout: no recursive Apply, no stale
            // frame using the old native fill geometry behind the new outline.
            ((void (*)(id, SEL))objc_msgSend)(slider, @selector(layoutSubviews));
        }
        for (UIView *surface in VGCCSurfaces(slider))
            VGCCRoundSurface(surface, radius, state.surfaceSnapshots,
                surface != slider && ![slider isDescendantOfView:surface]);
        state.applied = state.surfaceSnapshots.count > 0;
    } else {
        BOOL needsNativeLayout = state.modelOverridden;
        VGCCRestoreNativeModel(slider, state);
        if (needsNativeLayout)
            ((void (*)(id, SEL))objc_msgSend)(slider, @selector(layoutSubviews));
    }
    [CATransaction commit];
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
        !strstr(info.dli_fname, "/ControlCenterUI.framework/") &&
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
            if (state.applying) {
                ((void (*)(id, SEL))nextLayout)(slider, layout);
                return;
            }
            if (!state.layoutDepth) {
                state.applying = YES;
                VGCCRestoreSurfaces(state);
                BOOL active = VGEnabled() && (VGAutoCapsule() || VGRadius() > 0.5) && VGCCShouldRound(slider);
                if (!active) {
                    VGCCRestoreNativeModel(slider, state);
                } else {
                    // Seed the input BEFORE the first native fill layout. The
                    // previous build corrected it only afterwards, leaving one
                    // transition frame using mismatched track/fill geometry.
                    SEL getter = NSSelectorFromString(@"continuousSliderCornerRadius");
                    CGFloat configured = VGCCRadius(slider);
                    CGFloat current = ((CGFloat (*)(id, SEL))objc_msgSend)(slider, getter);
                    if (configured > 0 && fabs(current-configured) > 0.01) {
                        if (!state.modelOverridden) {
                            state.nativeRadius = current;
                            state.hasNativeRadius = YES;
                        }
                        [CATransaction begin];
                        [CATransaction setDisableActions:YES];
                        state.modelOverridden = YES;
                        ((void (*)(id, SEL, CGFloat))objc_msgSend)(slider,
                            NSSelectorFromString(@"setContinuousSliderCornerRadius:"), configured);
                        [CATransaction commit];
                    }
                }
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
            CGFloat effective = value;
            if (!state.radiusDepth) {
                state.applying = YES;
                VGCCRestoreSurfaces(state);
                state.applying = NO;
                state.nativeRadius = value;
                state.hasNativeRadius = YES;
                BOOL active = VGEnabled() && (VGAutoCapsule() || VGRadius() > 0.5) && VGCCShouldRound(slider);
                CGFloat configured = active ? VGCCRadius(slider) : 0;
                if (configured > 0) effective = configured;
                state.modelOverridden = fabs(effective-value) > 0.01;
            }
            // A subclass passes the already-resolved value through super.
            // Never record that effective value as the module's original one.
            state.radiusDepth++;
            ((void (*)(id, SEL, CGFloat))nextRadius)(slider, radius, effective);
            state.radiusDepth--;
            if (!state.radiusDepth) VGCCApply(slider);
        });
        MSHookMessageEx(cls, radius, radiusHook, &nextRadius);
        MSHookMessageEx(cls, layout, layoutHook, &nextLayout);
        [VGCCInstalledClasses addObject:name];
    }
    // Mark intent before the module changes its BOOL or performs any animation
    // layout. These are real module/view APIs, not the iOS 17 slider callback.
    for (NSArray<NSString *> *entry in @[
        @[@"CCUIDisplayModuleViewController", @"willTransitionToExpandedContentMode:"],
        @[@"CCUIDisplayModuleViewController", @"didTransitionToExpandedContentMode:"],
        @[@"MRUVolumeViewController", @"didTransitionToExpandedContentMode:"],
        @[@"MediaControlsVolumeViewController", @"willTransitionToExpandedContentMode:"],
        @[@"MRUVolumeView", @"setExpanded:"]]) {
        NSString *key = [entry componentsJoinedByString:@"|"];
        if ([VGCCInstalledClasses containsObject:key]) continue;
        Class cls = objc_getClass(entry[0].UTF8String);
        SEL selector = NSSelectorFromString(entry[1]);
        if (!cls || !VGCCHasMethod(cls, selector)) continue;
        __block IMP next = NULL;
        IMP hook = imp_implementationWithBlock(^(id owner, BOOL expanded) {
            objc_setAssociatedObject(owner, VGCCExpandedIntentKey, @(expanded), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ((void (*)(id, SEL, BOOL))next)(owner, selector, expanded);
            // Existing visible sliders are ready for the next render commit.
            // Sliders created by this transition go through the pre-layout hook.
            for (UIView *slider in VGCCSliders.allObjects) {
                for (UIResponder *r = slider; r; r = r.nextResponder) {
                    if (r != owner) continue;
                    VGCCApply(slider);
                    [slider setNeedsLayout];
                    break;
                }
            }
        });
        MSHookMessageEx(cls, selector, hook, &next);
        [VGCCInstalledClasses addObject:key];
    }
    // The module platter has its OWN corner-radius input. Changing only the
    // slider leaves that background at the old rounded rectangle until a value
    // change happens to trigger another layout pass. Supply the expanded shape
    // to the module host at the source, before it builds its transition.
    for (NSString *name in @[@"CCUIDisplayModuleViewController", @"MRUVolumeViewController", @"MediaControlsVolumeViewController"]) {
        NSString *key = [name stringByAppendingString:@"|expandedPlatterRadius"];
        if ([VGCCInstalledClasses containsObject:key]) continue;
        Class cls = objc_getClass(name.UTF8String);
        SEL selector = NSSelectorFromString(@"preferredExpandedContinuousCornerRadius");
        SEL widthSelector = NSSelectorFromString(@"preferredExpandedContentWidth");
        SEL heightSelector = NSSelectorFromString(@"preferredExpandedContentHeight");
        if (!cls || !VGCCHasMethod(cls, selector) || !VGCCHasMethod(cls, widthSelector) || !VGCCHasMethod(cls, heightSelector)) continue;
        __block IMP next = NULL;
        IMP hook = imp_implementationWithBlock(^CGFloat(id owner) {
            CGFloat original = ((CGFloat (*)(id, SEL))next)(owner, selector);
            CGFloat width = ((CGFloat (*)(id, SEL))objc_msgSend)(owner, widthSelector);
            CGFloat height = ((CGFloat (*)(id, SEL))objc_msgSend)(owner, heightSelector);
            if (!isfinite(width) || !isfinite(height) || width <= 1 || height <= 1) return original;
            return MAX(0, MIN(width, height) * 0.5 - 0.5);
        });
        MSHookMessageEx(cls, selector, hook, &next);
        [VGCCInstalledClasses addObject:key];
    }
    // Host container layout can reset _moduleMaterialView AFTER the child
    // slider has already applied its surfaces. Reconcile after that exact host,
    // not via touch events or a recurring timer, and never touch other modules.
    {
        NSString *key = @"CCUIContentModuleContentContainerView|layout";
        Class cls = objc_getClass("CCUIContentModuleContentContainerView");
        SEL selector = @selector(layoutSubviews);
        if (cls && ![VGCCInstalledClasses containsObject:key] && VGCCHasMethod(cls, selector)) {
            __block IMP next = NULL;
            IMP hook = imp_implementationWithBlock(^(UIView *container) {
                ((void (*)(id, SEL))next)(container, selector);
                for (UIView *slider in VGCCSliders.allObjects) {
                    if (![slider isDescendantOfView:container]) continue;
                    VGCCSliderState *state = VGCCState(slider);
                    if (state.applying || state.layoutDepth || state.radiusDepth) continue;
                    VGCCApply(slider);
                }
            });
            MSHookMessageEx(cls, selector, hook, &next);
            [VGCCInstalledClasses addObject:key];
        }
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
