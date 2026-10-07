# Architecture

## 模块

- `android/.../MainActivity.kt`：Flutter 通道、MediaProjection 授权入口。
- `android/.../MonitoringService.kt`：前台服务、原生周期调度、VirtualDisplay、ImageReader 和 PNG 落盘。
- `lib/services/monitoring_service.dart`：接收原生事件，创建队列记录，向 UI 发布状态。
- `lib/repositories/monitor_repository.dart`：SQLite 队列与历史记录。
- `lib/services/sync_service.dart`：上传/记录两阶段同步、重试和成功后清理。
- `lib/services/siyuan_service.dart`：所有 SiYuan HTTP API 调用和精简日志 Markdown 生成。
- `lib/screens/`：配置、运行状态、历史列表与详情。

## 捕获与同步状态流

```text
MediaProjection permission
  → Foreground Service
  → ImageReader frame
  → PNG in app files/screenshots
  → MonitorRecord(capture=success, sync=pending)
  → MiMo Token Plan vision analysis
  → MonitorRecord(analysis=completed, character/prompt/task)
  → ensureFolderStructure
  → append compact text log
  → MonitorRecord(sync=success, siyuanBlockId=...)
  → delete temporary PNG
```

识别或日志写入失败时记录转为 `sync=failed`，PNG 保留。首次失败后等待 5 秒，第二次等待 30 秒，第三次等待 60 秒；三次自动重试后保留记录。下一次应用会话或重新开始监控时会开启新一轮重试。

## 恢复与去重

SQLite 保存同步状态。原生层还会在 Flutter 事件监听重新连接时枚举未删除 PNG，覆盖“截图已落盘但 Dart 尚未入队”窗口。Dart 使用截图绝对路径生成 UUID v5，同一文件被重新发现时复用同一记录，避免重复入队。

## SiYuan 记录

应用通过 SQL 查询解析用户配置的目标子文档 ID，校验它所属的笔记本。写入前使用 `getIDsByHPath` 查询当天的 `YYYY-MM-DD` 子文档：存在时稳定复用最早创建的文档，不存在时才调用 `createDocWithMd`，并在创建后再次查询验证。进程内还会合并同一天的并发创建请求，避免多个同步任务同时创建同名文档。每条记录写入识别日志、绿色提示原文和识别置信度；配置勾选时额外上传并嵌入截图，始终不附加 JSON。角色名来自 MiMo 对截图左上角区域的识别，用户无需输入；识别或同步失败时，本地 PNG 与队列记录保留并重试。

## MediaProjection 生命周期

服务注册 `MediaProjection.Callback`。系统撤销投屏、投影异常或授权数据无效时，服务释放 VirtualDisplay/ImageReader、移除前台通知、将状态设为 stopped，并通过 EventChannel 报告 `permissionRequired=true`。服务采用 `START_NOT_STICKY`，避免进程重启后在没有有效授权时伪装成运行状态。
