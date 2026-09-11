FIRMWARE_ROOTFS_VER=3.9
FIRMWARE_BUILDS_VER=099
# 使用构建时间戳作为固件版本尾码，避免把Git提交短SHA显示为版本号。
FIRMWARE_BUILDS_REV=$(shell date -u +%y%m%d_%H%M)
