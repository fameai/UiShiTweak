ARCHS = arm64 armv7 # KEEP THIS AS ARM64 AND ARMV7 NO MATTER WHAT!!!
TARGET = iphone:clang:latest:10.0 # KEEEP THIS AT 10.0

THEOS_DEVICE_IP = 192.168.4.34
# PACKAGE_VERSION = 1.0
DEBUG = 0

# Rootless support
ifeq ($(ROOTLESS),1)
  THEOS_PACKAGE_SCHEME = rootless
endif

# Force ad-hoc signing
ADDITIONAL_CODESIGN_FLAGS = -S

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = UiShi

UiShi_FILES = Tweak.x HTTPServer.m
UiShi_CFLAGS = -fobjc-arc
ifeq ($(DEBUG),1)
    UiShi_CFLAGS += -DDEBUG=1
endif
UiShi_LDFLAGS =

include $(THEOS)/makefiles/tweak.mk

internal-stage::
	@echo "Running fix_libs script"
	$(ECHO_NOTHING)chmod +x fix_libs.sh$(ECHO_END)
	$(ECHO_NOTHING)./fix_libs.sh$(ECHO_END)
	
	@echo "Copying libHandleURLScheme.dylib and frameworks"
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/Frameworks/$(ECHO_END)
	$(ECHO_NOTHING)cp -R layout/Library/Frameworks/* $(THEOS_STAGING_DIR)/Library/Frameworks/$(ECHO_END)
	
	# Copy main dylib and ensure it's signed
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/$(ECHO_END)
	$(ECHO_NOTHING)cp libs/libHandleURLScheme.dylib \
		$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/$(ECHO_END)
	$(ECHO_NOTHING)ldid -S $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/libHandleURLScheme.dylib$(ECHO_END)

after-install::
ifneq ($(ROOTLESS),1)
	install.exec "sbreload"
else
	install.exec "killall -9 SpringBoard"
endif 