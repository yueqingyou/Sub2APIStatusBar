# TokenRouter Monitor 固件

本目录是 ESP32-S3-RLCD-4.2 的正式 ESP-IDF 固件。当前版本为 `0.5.1-data-sync`，包含概览、任务、配额和设备四页；短按板载 `KEY` 依次切页，长按 1.5 秒开启 60 秒 BLE 配对窗口。每页使用独立的大数值层级和留白分组，不复用圆角卡片网格，也不使用装饰性分隔线。电池测量和定时休眠尚未启用。

未绑定且配对窗口关闭时，设备不广播项目服务。长按允许一台 Mac 使用 LE Secure Connections Just Works 建立加密绑定；已有绑定不会被普通长按单方删除，绑定保存在 NVS，重启后可自动恢复。由于开发板没有密码或数字确认输入，该模式不提供 MITM 认证；实体长按和 60 秒窗口是授权边界。

安全链路使用协议版本 2。握手只确认兼容性；随后 Mac 根据设备当前页发送低频脱敏快照，不发送实时并发、活动任务、运行数或等待数。独立轻量心跳只更新 Mac、网络和 TokenRouter 在线状态；关闭独立检查时，离线超时自动跟随当前页的完整同步周期。设备不会接收凭据、账号身份或原始 API 响应。相同数据仍会更新在线计时，但不会触发整屏重绘。

固件固定使用 ESP-IDF 5.5.2，并通过 ESP Component Registry 固定使用 `nixy4/u8g2` 0.1.4。ST7305 初始化参数、屏幕引脚和分区布局基于 Waveshare 官方示例，并在本项目实物上完成验证。

`components/u8g2_st7305/` 基于 Waveshare 的 Apache-2.0 示例修改，目录内保留原始版权、许可证副本和修改声明。通过 ESP Component Registry 获取的 U8g2 仍适用其自身许可证。

构建前先加载基于 MacPorts Python 3.12 的 ESP-IDF 5.5.2 环境，然后在本目录执行 `idf.py build`。构建目录、自动下载的组件和本机 `sdkconfig` 不提交；从旧版固件切换后，应移走旧 `sdkconfig` 让 `sdkconfig.defaults` 重新生效。组件版本由 `idf_component.yml` 和 `dependencies.lock` 共同固定。顶层 CMake 会拒绝带空格编号的组件冲突副本，生成烧录候选时仍需使用两个独立构建目录比较三段镜像。
