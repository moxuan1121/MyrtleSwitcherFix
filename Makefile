ARCHS = arm64e
TARGET = iphone:clang:15.6:15.0
THEOS_PACKAGE_SCHEME = roothide
DEB_ARCH = iphoneos-arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MyrtleSwitcherFix

MyrtleSwitcherFix_FILES = Tweak.xm
MyrtleSwitcherFix_CFLAGS = -fobjc-arc -Wall -Wextra
MyrtleSwitcherFix_FRAMEWORKS = Foundation UIKit
MyrtleSwitcherFix_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

# Intentionally no install/uninstall command that restarts or modifies ElleKit.
# Respring manually after installation/removal.
