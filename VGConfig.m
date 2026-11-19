#import "VGConfig.h"

// Fixed install-and-use profile. Old preference files are deliberately ignored
// without deleting user data, so an earlier Enabled=NO cannot disable this build.
NSString *const VGDomain = @"com.shiyi.volumeglass";
NSString *const VGChangedNotification = @"com.shiyi.volumeglass-changed";
BOOL VGEnabled(void) { return YES; }
BOOL VGRimEnabled(void) { return NO; }
BOOL VGExtraBlur(void) { return NO; }
BOOL VGApplyToBrightness(void) { return NO; }
BOOL VGDebugEnabled(void) { return NO; }
BOOL VGAutoCapsule(void) { return YES; }
BOOL VGSlideIn(void) { return YES; }
BOOL VGKillHalo(void) { return NO; }
BOOL VGReplaceSkin(void) { return YES; }
CGFloat VGRadius(void) { return 26; }
CGFloat VGCornerPercent(void) { return 100; }
CGFloat VGTintAlpha(void) { return 0; }
NSInteger VGLevelUp(void) { return 0; }
NSString *VGClassOverride(void) { return nil; }
void VGConfigMigrate(void) { /* No preferences to migrate in the fixed profile. */ }
void VGLog(NSString *fmt, ...) { (void)fmt; }
