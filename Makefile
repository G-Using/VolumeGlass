TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

# RootHide / Rootless 通用：不写任何绝对路径，靠 dyld + 偏好域工作
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VolumeGlass
VolumeGlass_FILES = Tweak.xm VGConfig.m VGDecor.m
VolumeGlass_CFLAGS = -fobjc-arc
VolumeGlass_FRAMEWORKS = UIKit QuartzCore
VolumeGlass_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = VolumeGlassPrefs
VolumeGlassPrefs_FILES = VGRootListController.m
VolumeGlassPrefs_INSTALL_PATH = /Library/PreferenceBundles
VolumeGlassPrefs_FRAMEWORKS = UIKit
VolumeGlassPrefs_PRIVATE_FRAMEWORKS = Preferences
VolumeGlassPrefs_CFLAGS = -fobjc-arc
# theos 只发 -framework 不发 -F，私有框架搜索路径要自己补
VolumeGlassPrefs_LDFLAGS = -F$(TARGET_PRIVATE_FRAMEWORK_PATH)

include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 SpringBoard"
