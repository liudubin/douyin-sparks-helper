TARGET = iphone:clang:latest:15.0
ARCHS = arm64

INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SparksHelper

SparksHelper_FILES = src/Tweak.x src/SparksConfig.m src/SparksEngine.m src/SparksAI.m src/SparksLicense.m src/SparksPanel.m
SPARKS_VERSION := $(shell grep '^Version:' control | awk '{print $$2}')
SPARKS_BUILD_TIME := $(shell TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M')
SparksHelper_CFLAGS = -fobjc-arc -Isrc -Wno-deprecated-declarations \
  -DSPARKS_VERSION='"$(SPARKS_VERSION)"' \
  -DSPARKS_BUILD_TIME='"$(SPARKS_BUILD_TIME)"'
SparksHelper_FRAMEWORKS = UIKit Foundation PhotosUI Photos UniformTypeIdentifiers ImageIO CoreGraphics AVFoundation AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk
