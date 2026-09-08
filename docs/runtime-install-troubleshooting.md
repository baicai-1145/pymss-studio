# 运行环境安装排障指南

适用版本：manifest 2026.08.1+。安装日志位于
`<runtime-envs>/<backend>/pymss-runtime-install.log`（界面"查看日志"直达）。

## 错误码速查

| 错误码 | 含义 | 处理 |
|---|---|---|
| `RUNTIME_INSTALL_FAILED` | pip 阶段失败 | 看日志定位阶段（torch / common / pymss），按下方场景处理 |
| `RUNTIME_PERMISSION_DENIED` | 目录被占用/无权限 | 关闭占用程序（杀毒软件扫描 torch DLL 时常见），重试 |
| `RUNTIME_PLATFORM_UNSUPPORTED` | 后端与系统不匹配 | 例如在 Windows 上装 mlx；选择正确后端 |
| `RUNTIME_NOT_INSTALLED` | 环境不存在或状态缺失 | 设置里重新安装 |
| `RUNTIME_ACTIVATION_FAILED` | 环境探针未通过 | 日志会给出 torchBackend/缺失包；重装该环境 |
| `RUNTIME_CORE_UPDATE_FAILED` | 核心更新失败 | 日志在 `<backend>/pymss-core-update.log`；重试或重装 |

提示：安装日志中出现 `Insufficient disk space` 时，清理目标盘（CUDA 环境至少
10 GiB）后重试。

## 常见场景

### 1. 下载缓慢 / 超时（尤其 torch）

- 设置中切换 PyPI 镜像（清华/中科大/阿里云）。torch 本体走 pytorch.org，
  不受 PyPI 镜像影响——torch 阶段慢属于 pytorch.org 的网络问题。
- 使用代理：设置 → 代理，安装任务会继承代理配置。

### 2. 取消/失败后重装又从零开始

新版本共享 pip 缓存（数据目录下 `pip-cache/`），重装只补缺失部分。若缓存目录
损坏（日志出现 cache 相关报错），删除该目录即可，不影响已装环境。

### 3. 杀毒软件 / 文件锁定（Windows）

torch/numba 的 DLL 常被实时扫描锁定，`rmtree` 失败或 pip 写入失败：
- 将安装目录加入白名单；
- 关闭"访问保护"后重试；
- 失败残留会被识别为"未完成的环境"，UI 可一键回收磁盘。

### 4. 路径含特殊字符导致 venv 创建失败

已在上游修复（路径统一规范化）。若仍复现，提供安装日志中 venv 阶段的完整
报错（含 `\\?\` 前缀或非 ASCII 路径片段）提 issue。

### 5. pymss 安装阶段报依赖冲突

新版本安装 pymss 时启用依赖解析并用 `torch==<已装版本>` 约束保护 torch。报
冲突说明 pymss 新版本要求的依赖与当前 torch 构建不兼容——这属于预期保护，
等待新版 manifest 或在 issue 中附日志。

### 6. 便携版升级后环境"消失"

受管更新只替换 exe 与 `python/`，`python-runtime/runtime-envs/` 保留。若
`active-runtime.json` 指向失效路径，应用启动时会回退到内置环境；手动删除数据
目录下的 `runtime-envs/active-runtime.json` 可强制重新探测。

## 诊断信息收集

设置 → 开发者模式开启后，诊断报告包含：worker 命令行、探针输出、安装日志。
提 issue 时附上 `pymss-runtime-install.log` 全文与错误码。
