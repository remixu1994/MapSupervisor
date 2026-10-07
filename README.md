# MapSupervisor

MapSupervisor 是面向 Android 云手机的 Flutter 监控应用。它通过 Android MediaProjection 在前台服务中临时截图，调用 MiMo Token Plan 视觉模型识别左上角角色名称和顶部绿色提示，再将精简文字日志写入 SiYuan。截图默认只用于识别，也可选择上传到 SiYuan；SQLite 会持久保存尚未完成的记录。

## 架构

```text
冒险岛：枫之传说
        ↓
Android Screen
        ↓
MediaProjection
        ↓
MonitoringService（Android Foreground Service）
        ↓ MethodChannel / EventChannel
本地 PNG + SQLite Queue
        ↓
MiMo Token Plan（截图识别）
        ↓
SiyuanService
        ↓
SiYuan Notebook / MapSupervisor / YYYY-MM-DD
        ↓
Hermes Agent（异步读取，本项目不包含）
```

更详细的模块边界和数据流见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 功能

- 默认每 25 分钟监控一次，间隔可按分钟配置。
- 支持手动调试：8 秒倒计时内切回游戏，然后截图、调用 MiMo 识别并写入 SiYuan。
- 持久保存 SiYuan 配置、MiMo Token Plan 配置和监控间隔。
- 支持通过 Android 系统文件选择器导入、导出 JSON 配置，重装后可快速恢复参数。
- MiMo 识别左上角角色名、顶部绿色提示、任务编号和执行内容。
- 使用 MediaProjection，无需 root。
- 原生 Android 前台服务负责周期调度，不使用 Flutter UI `Timer`。
- 支持开始、停止、立即测试截图和 SiYuan 连接测试。
- PNG 文件名为 `yyyyMMdd_HHmmss.png`。
- SQLite 持久队列在进程重启后恢复；失败后按 5、30、60 秒自动重试三次。
- 日志写入成功前保留本地 PNG；成功后立即删除临时 PNG。
- “上传截图到 SiYuan”默认关闭；勾选后上传并嵌入截图，不勾选时只写入文字。两种模式都不附加 JSON。
- SiYuan 中在目标子文档下按 `YYYY-MM-DD` 聚合每日记录：先查询并复用当天文档，仅在不存在时创建。
- 历史页面显示捕获、识别、同步状态、Block ID 和错误信息。
- MediaProjection 被撤销时停止服务，并在 UI 明确提示重新授权。
- 提供可拖动悬浮控制条，支持左右侧边吸附、收起和点击展开，并记忆位置。
- 监控期间检测横竖屏尺寸变化，通过复用并调整虚拟显示避免 Android 14 重复创建 MediaProjection 导致崩溃。

## 环境要求

- Flutter 3.44 或兼容的稳定版
- Dart 3.12 或兼容版本
- Android SDK（compile/target SDK 由 Flutter 当前稳定版提供）
- JDK 17
- Android 9（API 28）或更高版本（包括雷电 9 与 Android 14）
- 可从云手机访问的 SiYuan HTTP API

## SiYuan 配置

1. 在 SiYuan 的“设置 → 关于”中复制 API Token。
2. 填写目标笔记本 ID，以及该笔记本内用于存放日志的目标子文档 ID。应用会在这个子文档下面创建 `YYYY-MM-DD` 日期文档。
3. `SiYuan Server` 填可被 Android 设备访问的地址，例如 `http://192.168.1.2:6806`；真机不能用电脑自身的 `127.0.0.1`。
4. 确认防火墙和 SiYuan 网络服务允许云手机访问。
5. 先点击“测试 SiYuan 连接”。

应用调用以下 SiYuan API：

- `POST /api/system/version`
- `POST /api/asset/upload`（仅在勾选上传截图时）
- `POST /api/filetree/createDocWithMd`
- `POST /api/filetree/getIDsByHPath`
- `POST /api/query/sql`
- `POST /api/block/appendBlock`
- `POST /api/block/updateBlock`（为后续记录更新预留）

鉴权头为 `Authorization: Token <token>`。Token 仅保存在应用运行时配置中，不会写入源码或日志。当前 MVP 使用 `shared_preferences`，它不是硬件级加密存储；高安全环境应迁移到 Android Keystore-backed 存储。

## MiMo Token Plan 配置

1. 在 MiMo Token Plan 控制台复制 `tp-` 开头的 API Key。
2. 中国区默认地址为 `https://token-plan-cn.xiaomimimo.com/v1`；若套餐控制台给出专属区域地址，以控制台地址为准。
3. 视觉模型填写 `mimo-v2.5`。`mimo-v2.5-pro` 是文本模型，不用于本应用的截图识别。
4. 应用通过 OpenAI 兼容的 `POST /chat/completions` 发送当前截图；每次识别使用独立请求，不复用历史图片会话。

MiMo API Key 与 SiYuan Token 一样保存在 `shared_preferences`，不会写入源码或日志，但不是硬件级加密存储。

## 运行

```bash
flutter pub get
flutter run
```

首次开始监控时，Android 会显示系统屏幕捕获确认框。批准后通知栏应出现“MapSupervisor 正在监控”。打开游戏后，前台服务仍会按配置间隔捕获。

首页“JSON 配置文件”区域可导出当前配置，重装后再通过“导入配置”恢复。导出文件包含 SiYuan Token 和 MiMo API Key，必须作为敏感文件妥善保管，仓库已默认忽略 `MapSupervisor-config.json`。

“手动调试”会请求一次截图授权；授权后请在 8 秒内切回游戏，随后应用完成截图、MiMo 识别与 SiYuan 写入。任一网络步骤失败时，PNG 和队列记录会保留，以便后续重试。

## Android 权限

- `INTERNET`：访问 SiYuan API。
- `FOREGROUND_SERVICE`：运行前台服务。
- `FOREGROUND_SERVICE_MEDIA_PROJECTION`：声明现代 Android 的屏幕捕获服务类型。
- `POST_NOTIFICATIONS`：Android 13+ 显示监控通知。
- `WAKE_LOCK`：为云手机厂商的后台运行策略预留。

MediaProjection 授权由系统弹窗动态授予，不是 Manifest 普通权限。授权不会跨设备重启持久化。

## 验证

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
```

Android 手工验收：

1. 安装并启动应用，配置默认间隔 `25` 分钟、SiYuan 参数和 MiMo Token Plan 参数。
2. 点击“测试 SiYuan 连接”，确认成功。
3. 点击“手动调试（8 秒后截图并识别）”，批准系统授权后立即切回游戏，确认历史中出现角色名、绿色提示和执行内容。
4. 点击“开始监控”，再次按系统要求授权。
5. 切换到游戏并停留至少 5 分钟。
6. 测试时可暂时把间隔设为 `1` 分钟；确认通知持续存在且历史中产生多条记录。
7. 在 SiYuan 中确认目标子文档下的 `YYYY-MM-DD` 文档只包含格式化文字日志，没有截图和 JSON。
8. 断开网络并等待一次捕获，确认失败记录和本地 PNG 保留；恢复网络并重启应用或重新开始监控，确认自动重试。
9. 在系统中停止投屏/录屏授权，确认应用显示“需要重新授予屏幕捕获权限”，且不继续假报运行中。

## 已知限制

- Android 或云手机厂商可能撤销 MediaProjection；必须返回应用重新授权。
- 进程被系统彻底杀死后，授权不可恢复，前台服务不会无授权自启动。
- 某些云手机需要额外关闭电池优化、开启后台运行或锁定任务。
- 如果游戏使用 Android `FLAG_SECURE` 禁止录屏，MediaProjection 可能只能得到黑屏；这属于目标应用的系统级限制。
- 日志写入成功后临时 PNG 会删除，历史详情中的本地缩略图随之不可用；截图不会上传到 SiYuan。
- Token 当前由 `shared_preferences` 保存，不等同于加密保险库。
- 识别依赖截图清晰度与 MiMo 模型结果；应用不执行点击模拟或自动控制。

## 数据与隐私

屏幕截图可能包含敏感信息。应用只将截图发送到用户配置的 MiMo Token Plan API 用于识别，写入 SiYuan 的只有精简文字日志；不包含预置服务器或 Token。发布前请配置正式签名；仓库默认 release 构建仍使用 Flutter 模板的 debug 签名。
