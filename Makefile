TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

# RootHide / Rootless 通用：不写任何绝对路径，靠 dyld + 偏好域工作
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VolumeGlass
VolumeGlass_FILES = Tweak.xm VGConfig.m VGDecor.m VGControlCenter.m
VolumeGlass_CFLAGS = -fobjc-arc
VolumeGlass_FRAMEWORKS = UIKit QuartzCore
VolumeGlass_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
