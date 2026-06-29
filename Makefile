# Rootful: iOS 13.0+, Rootless: iOS 15.0+, Roothide: iOS 15.0+
ARCHS = arm64 arm64e
FINALPACKAGE = 1
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
    TARGET := iphone:clang:latest:15.0
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    TARGET := iphone:clang:latest:15.0
else
    TARGET := iphone:clang:latest:13.0
endif

SUBPROJECTS += mcp-root

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = com.susu.mcp
BUNDLE_NAME = iosmcpprefs

com.susu.mcp_FILES = Tweak.x MCPServer.m MCPProcessUtil.m
com.susu.mcp_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
com.susu.mcp_FRAMEWORKS = IOKit UIKit CoreGraphics QuartzCore MobileCoreServices AVFoundation Security

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    com.susu.mcp_LIBRARIES = roothide
    com.susu.mcp_CFLAGS += -DMCP_ROOTHIDE=1
    iosmcpprefs_LIBRARIES = roothide
else ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
    com.susu.mcp_CFLAGS += -DMCP_ROOTLESS=1
endif

iosmcpprefs_FILES = prefs/IOSMCPRootListController.m
iosmcpprefs_CFLAGS = -fobjc-arc
iosmcpprefs_FRAMEWORKS = UIKit CoreGraphics
iosmcpprefs_PRIVATE_FRAMEWORKS = Preferences
iosmcpprefs_LDFLAGS = -F$(THEOS)/sdks/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks
iosmcpprefs_INSTALL_PATH = /Library/PreferenceBundles
iosmcpprefs_RESOURCE_DIRS = prefs/Resources

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	$(ECHO_NOTHING)cp prefs/entry/ios-mcp.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/com.susu.mcp.plist"$(ECHO_END)
	@# Bundle mcp-root (setuid root helper for running commands as root from mobile)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/usr/bin"$(ECHO_END)
	$(ECHO_NOTHING)$(MAKE) -C mcp-root $(if $(THEOS_PACKAGE_SCHEME),THEOS_PACKAGE_SCHEME=$(THEOS_PACKAGE_SCHEME))$(ECHO_END)
	$(ECHO_NOTHING)cp mcp-root/.theos/obj/mcp-root "$(THEOS_STAGING_DIR)/usr/bin/mcp-root"$(ECHO_END)
	$(ECHO_NOTHING)chmod 4755 "$(THEOS_STAGING_DIR)/usr/bin/mcp-root"$(ECHO_END)

after-install::
	install.exec "killall -9 SpringBoard"
