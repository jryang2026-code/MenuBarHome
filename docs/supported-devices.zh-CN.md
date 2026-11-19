# 我的设备能用吗？

[← 返回 README](../README.zh-CN.md)

按设备类型速查。「可控」表示面板能开关或调节；「只读」表示只显示状态，不能在这里下指令。每一行都标明了它对应 [`capabilities.json`](capabilities.json) 里的哪项能力，`scripts/check_supported_devices.py` 会在 lint 里检查本页与该文件是否一致。

本页说的是通过 **米家**（扫码登录）或 **Home Assistant** 接入的设备。两者都没有的设备不在支持范围内。

## 按设备类型

| 设备 | 状态 | 说明 | 来源 |
| :--- | :--- | :--- | :--- |
| 灯、灯组 | 可控 | 亮度、色温、预设；灯组成员默认折叠进灯组卡片 | — |
| 插座、开关 | 可控 | 每日电量记录；打开前会先确认 | `plug-energy` |
| 空调、取暖器、电热毯 | 可控 | 目标温度、模式；打开取暖器前会先确认 | — |
| 风扇、除湿机 | 可控 | 风速与设备上报的模式 | `dehumidifiers-blankets-diffusers-speakers` |
| 窗帘、开窗器、晾衣架 | 可控 | 位置与行程状态；开窗和放下晾衣架前会先确认 | `covers-curtains` |
| 空气净化器、净味器、加湿器 | 可控 | PM2.5、滤芯寿命、风量 | `air-purifiers` |
| 热水器 | 可控 | 打开或调高目标温度前会先确认 | `water-heaters` |
| 浴霸、油烟机 | 可控 | 合并成一张卡片：取暖、风量、灯 | `bath-heaters-hoods` |
| 洗衣机、烘干机、洗碗机 | 可控 | 程序列表、剩余时间；启动前会先确认 | `laundry-appliances` |
| 冰箱、水壶、电饭煲、烤箱 | 可控 | 温度与模式；型号提供时可启动 / 暂停 | `fridges-kitchen` |
| 扫地机器人 | 可控 | 启动前会先确认 | — |
| 音箱 | 可控 | 音量、静音、播放状态 | `dehumidifiers-blankets-diffusers-speakers` |
| 摄像机、可视门铃 | 可控 | 实时画面；已验证的型号支持双镜头与云台 | `camera-live` |
| 鱼缸、喂食器 | 可控 | 走通用卡片；喂食前会问份量 | `fish-tanks-pet-feeders` |
| LG webOS 电视 | 可控 | 局域网直连，在设置里配置 | — |
| 门锁 | 只读 | 电量；型号上报时显示已锁 / 未锁。小米规格不提供远程开锁 | `locks-sensors` |
| 人体、门窗、水浸、光照、空气质量传感器 | 只读 | 读数；温度、湿度、PM2.5、光照另有 24 小时与 7 天曲线 | `sensor-history` |
| 网关、路由器、中继器 | 只读 | macOS 上型号有可用项时给一张通用卡片，否则列入「被跳过」 | `generic-device-cards` |
| 米家里的其他设备 | 通用卡片 | 名称、房间、最多两项读数和一个低风险开关，其余在「更多设置」 | `generic-device-cards` |

## 不在支持范围内的

- **无状态的无线遥控器和按钮**：没有可读的状态，也没有可下的指令。
- **不在米家或 Home Assistant 里的设备**，比如只能在厂商自家 App 里用的空调。如果 Home Assistant 能看到它，请改为连接 Home Assistant。
- **开门**：米家的接口不提供远程开锁，所以门锁保持只读。

## 我的设备没出现，或者显示不对

1. 打开 **设置 → 关于与诊断 → 未能显示在面板的设备** 扫描一次，它会列出被跳过的设备和原因（macOS）。
2. 如果被跳过或显示不对，请[提一个「设备不支持」issue](https://github.com/jryang2026-code/MenuBarHome/issues/new?template=unsupported_device.yml)。请提供型号，不要贴设备 id 或令牌。
