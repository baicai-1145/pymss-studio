# ADR 0001: 运行环境管理——继续 venv + pip，根因修复后重评 uv

- 状态: 已接受 (2026-09)
- 决策人: @baicai-1145

## 背景

应用的"安装依赖"（用户侧安装 CPU/CUDA/MLX Python 环境）在历史上被反复
修补（`fix(runtime)` 系列 20 余次提交），始终没有根治。2026-09 的根因分析确认
了四个结构性原因：

1. **Windows `\\?\` 扩展路径前缀**：Rust `canonicalize()` 的产物经环境变量传入
   Python，venv/ensurepip 间歇性失败。下游累计打了五层防御补丁。
2. **venv 生命周期是"每次触碰都修复"**：安装入口有 4 个损坏分支，每次列表刷新
   都重写 relocatability。
3. **依赖解析策略不统一**：构建期与用户安装期两份硬编码清单；`pymss --no-deps`
   安装导致新增依赖被静默丢弃（多次"依赖回归"事故的根源）。
4. **状态多份真相**：active-runtime.json / pymss-runtime-state.json / Rust 反推
   校验三处并存，出现过"CPU 环境显示 cu128"类的 UI 谎言。

同时用户侧安装等于每次安装一次**不可复现的实时解析**，存在解析漂移与供应链
风险；且 pip 无缓存导致取消重装需重新下载数 GB。

## 决策

**近期（已实施，本分支）**：保留 venv + pip 体系，消除根因而非继续打补丁：

- Rust 侧统一去 `\\?\` 前缀（`src-tauri/src/paths.rs`），路径出进程前必经
  `display_normalized`；Python 侧 `_normal_runtime_path` 降级为旧状态兼容层。
- `python/runtime-manifest.json` 成为唯一清单；构建脚本（ps1/sh）改为运行时从
  manifest 解析，删除全部硬编码副本。
- pymss/pymss-core 安装改为**带依赖解析 + `--constraint torch==<已装版本>`**，
  同时覆盖构建期与用户安装期（原来两条路径两套策略）。
- 共享 pip 缓存（Rust 注入 `PIP_CACHE_DIR` 指向数据目录），取消重装不再重下。
- 安装前磁盘空间预检（manifest `minFreeDiskGB`）。
- CI 三层改造：fast-checks（脚本语法/manifest 门禁）、分层测试、
  release-rehearsal（定期真实跑发布打包流程）。

**远期（触发条件式重评）**：评估迁移到 [uv](https://docs.astral.sh/uv/)。
uv 单二进制 + 全局缓存 + 自管 venv，可整类消灭根因 1/2 的 pip 侧问题。
触发重评的条件（满足其一即开 spike 分支实测）：

1. 根因修复后，用户侧安装失败率仍显著（遥测上线后用数据说话）；
2. pip 安装时长成为明确用户痛点（CUDA 全程 > 15 分钟）；
3. 需要 `--require-hashes` 级别的供应链加固而 pip 方案维护成本过高。

spike 验收清单：离线分发（uv 二进制必须内置）、
恶劣路径矩阵（非 ASCII / 空格 / 超长路径）、取消重装、`pyvenv.cfg` relocatability。


### 后记（2026-09）：ROCm 后端先移除、后随上游 v2.1.5 重新引入

上游 pymss 一度未测试 ROCm（无 CI 矩阵、无基准、README 不声明），下游自建 ROCm backend 属于无背书的功能扩散，故先行移除。pymss v2.1.5 正式加入 ROCm 支持：`device="rocm"` 设备别名映射到 cuda 路径、官方 Windows 安装配方（repo.radeon.com 的 3 个 SDK wheel + torch 2.9.1+rocm7.2.1）、AOTriton SDPA 注意力路径。本分支据此重新引入 ROCm backend，配置完全对齐上游官方配方，并修正旧配置的缺陷：不再对 SDK/torch wheel 使用 `--no-deps`（旧配置会导致 torch 的 sympy/jinja2/networkx 等依赖缺失，torch 导入即失败）。当前 ROCm 仅支持通过应用内在线安装（Windows；Linux 依赖系统级 ROCm 驱动，超出 pip 可安装范围）。
