THEOS_DEVICE_IP = localhost
THEOS_DEVICE_PORT = 2222
THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NightModeExtender

NightModeExtender_FILES = Tweak.x Hooks_NoARC.m
NightModeExtender_CFLAGS = -fobjc-arc
NightModeExtender_FRAMEWORKS = UIKit Foundation
NightModeExtender_PRIVATE_FRAMEWORKS = CameraUI

# Disable ARC for the non-ARC hooks file (handles Swift struct params)
Hooks_NoARC.m_CFLAGS = -fno-objc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS = NightModeExtenderPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
