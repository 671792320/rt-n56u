FIRMWARE_ROOTFS_VER=3.9
# 固件版本号使用北京时间构建时间戳，格式：3.4.3.9-YYMMDDHHMM。
# 编译环境无论处于哪个时区，固件版本统一按中国北京时间（UTC+8）生成。
FIRMWARE_BUILDS_VER=$(shell TZ=Asia/Shanghai date +%y%m%d%H%M)
# 不使用Git提交号，避免版本号增加下划线和额外尾码。
FIRMWARE_BUILDS_REV=
