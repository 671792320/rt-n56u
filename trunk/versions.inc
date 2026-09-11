FIRMWARE_ROOTFS_VER=3.9
# 固件版本号直接使用构建时间戳，格式：3.4.3.9-YYYYMMDD_HHMM。
FIRMWARE_BUILDS_VER=$(shell date -u +%Y%m%d_%H%M)
# 保留Padavan原有REV变量，但不再使用Git提交短SHA作为固件版本号尾码。
FIRMWARE_BUILDS_REV=
