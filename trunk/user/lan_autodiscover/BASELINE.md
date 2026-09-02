# LAN监听与设备发现基础版本

当前版本作为后续网络接入与转发开发的基线。

已经实现：

- Q7 LAN4 物理链路检测。
- LAN监听、DHCP检测和设备发现开关。
- 设备发现结果按IP排序并分页显示。
- 设备数据库保存到 `/etc/storage/lan_discovery_devices.db`。
- 完整监听日志保存到 `/etc/storage/lan_discovery.log`。
- WebUI实时显示LAN接口、IPv4、MAC、链路状态、DHCP状态和发现数量。
- 发现结果及日志的异常字符清理。

当前阶段暂不加入目标网段临时地址、路由和SNAT，作为后续功能的独立基础版本。
