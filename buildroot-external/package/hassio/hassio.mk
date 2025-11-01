################################################################################
#
# HAOS
#
################################################################################

HASSIO_VERSION = 1.0.0
HASSIO_LICENSE = Apache License 2.0
# HASSIO_LICENSE_FILES = $(BR2_EXTERNAL_HASSOS_PATH)/../LICENSE
HASSIO_SITE = $(BR2_EXTERNAL_HASSOS_PATH)/package/hassio
HASSIO_SITE_METHOD = local
HASSIO_VERSION_URL = "https://version.home-assistant.io/"
ifeq ($(BR2_PACKAGE_HASSIO_CHANNEL_STABLE),y)
HASSIO_VERSION_CHANNEL = "stable"
else ifeq ($(BR2_PACKAGE_HASSIO_CHANNEL_BETA),y)
HASSIO_VERSION_CHANNEL = "beta"
else ifeq ($(BR2_PACKAGE_HASSIO_CHANNEL_DEV),y)
HASSIO_VERSION_CHANNEL = "dev"
endif

HASSIO_CONTAINER_IMAGES_ARCH = supervisor dns audio cli multicast observer core mycore

# === NEW: overlay 來源與 git helper image 版本 ===
HASSIO_OVERLAY_DIR = $(BR2_EXTERNAL_HASSOS_PATH)/board/overlay-homeassistant
GIT_HELPER_IMAGE  = alpine/git:v2.49.1

# 預設使用 linux/arm64（因為主要目標是 Raspberry Pi 5 / aarch64）
GIT_HELPER_PLATFORM = linux/arm64

GIT_HELPER_TAR = $(@D)/images/alpine-git-v2.49.1-$(BR2_PACKAGE_HASSIO_ARCH).tar
# ================================================

 
define HASSIO_CONFIGURE_CMDS 
	# Deploy only landing page for "core" by setting version to "landingpage"
	# .mycore = "2025.10.4" <-- 這邊就是改成你新的 image 版本，.images.mycore = "togetherlearn/{machine}-homeassistant" <-- 這邊就是改成你新的 image 名稱
	curl -s $(HASSIO_VERSION_URL)$(HASSIO_VERSION_CHANNEL)".json" | jq '.core = "landingpage" | .mycore = "2025.10.4" | .images.mycore = "togetherlearn/{machine}-homeassistant"' > $(@D)/version.json
endef

define HASSIO_BUILD_CMDS
	$(Q)mkdir -p $(@D)/images
	$(Q)mkdir -p $(HASSIO_DL_DIR)
	$(foreach image,$(HASSIO_CONTAINER_IMAGES_ARCH),\
		$(BR2_EXTERNAL_HASSOS_PATH)/package/hassio/fetch-container-image.sh \
			$(BR2_PACKAGE_HASSIO_ARCH) $(BR2_PACKAGE_HASSIO_MACHINE) $(@D)/version.json $(image) "$(HASSIO_DL_DIR)" "$(@D)/images"
	)

	@echo "預載 git 工具容器 GIT_HELPER_PLATFORM=$(GIT_HELPER_PLATFORM) (BR2_PACKAGE_HASSIO_ARCH=$(BR2_PACKAGE_HASSIO_ARCH))"
	@echo "Pulling $(GIT_HELPER_IMAGE) for $(GIT_HELPER_PLATFORM) ..."
	docker pull --platform $(GIT_HELPER_PLATFORM) $(GIT_HELPER_IMAGE)
	@echo "Saving $(GIT_HELPER_IMAGE) to $(GIT_HELPER_TAR) ..."
	docker save $(GIT_HELPER_IMAGE) -o $(GIT_HELPER_TAR)
endef

HASSIO_INSTALL_IMAGES = YES

define HASSIO_INSTALL_IMAGES_CMDS
	$(BR2_EXTERNAL_HASSOS_PATH)/package/hassio/create-data-partition.sh "$(@D)" "$(BINARIES_DIR)" "$(HASSIO_VERSION_CHANNEL)" "$(DOCKER_ENGINE_VERSION)" "$(HASSIO_OVERLAY_DIR)"
endef

# === NEW: 把 service + 腳本裝進 rootfs，並在 build 時建立 enable symlink ===
define HASSIO_INSTALL_TARGET_CMDS
	# 安裝 systemd 服務與腳本
	mkdir -p $(TARGET_DIR)/etc/systemd/system
	mkdir -p $(TARGET_DIR)/usr/local/sbin
	cp -a $(HASSIO_OVERLAY_DIR)/etc/systemd/system/ha-customcomponents-setup.service \
		$(TARGET_DIR)/etc/systemd/system/
	cp -a $(HASSIO_OVERLAY_DIR)/usr/local/sbin/ha-customcomponents-setup.sh \
		$(TARGET_DIR)/usr/local/sbin/
	chmod +x $(TARGET_DIR)/usr/local/sbin/ha-customcomponents-setup.sh

	# 在 build 階段建立 enable symlink（不在 Git 存 symlink，跨平台最穩）
	mkdir -p $(TARGET_DIR)/etc/systemd/system/multi-user.target.wants
	ln -sf ../ha-customcomponents-setup.service \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/ha-customcomponents-setup.service
endef
# ==============================================================================


$(eval $(generic-package))
