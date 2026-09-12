FIRMWARE_ROOTFS_VER=3.9
# 固件版本号使用紧凑构建时间戳，避免左上角升级页面显示不完整。
# 格式：3.4.3.9-YYMMDDHHMM，例如：3.4.3.9-2609120800。
FIRMWARE_BUILDS_VER=$(shell date -u +%y%m%d%H%M)
# 不再追加Git提交短SHA，避免版本号过长。
FIRMWARE_BUILDS_REV=
