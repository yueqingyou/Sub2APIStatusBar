# 项目约束

本文件约束本仓库后续所有 Codex 工作。

## API 证据

- 不得只根据界面意图推断 API 字段。涉及 Sub2API 的功能，在修改客户端模型前必须通过真实 API 探测和 `/Users/yuesir/Documents/Project/sub2api` 源码审查确认契约。
- `/Users/yuesir/Documents/Project/sub2api` 只作为只读上游源码检出用于契约审查。从本状态栏 App 工作时，不得修改该仓库的任何文件。
- 不得把 mock、占位或固定值后端接口接入用户可见指标。后端源码审查显示 `/api/v1/admin/dashboard/realtime` 返回固定 mock 实时值，不能作为实时并发显示来源。
- 用户要求显示“并发”时，必须理解为所选监控用户的实时占用并发槽位，不是用户配置的并发额度。
- 认证保持单账号模式。当前登录账号是管理员时，使用同一凭据启用管理员监控能力，并在设置中选择要监控的用户；当前登录账号是普通用户时，保持普通用户模式，不暴露实时并发、正常账号数等管理员专属监控项。
- 管理员模式下，除正常账号数等全局管理员指标外，用户余额、请求、费用、Token、最近记录、趋势、模型分布和订阅信息都必须按设置中选定的用户 ID 调用真实管理员接口；不得继续使用当前管理员账号的普通用户接口数据冒充所选用户数据。
- 如果某项所选用户数据没有真实管理员接口支撑，必须隐藏该项或显示明确不可用状态；不得兜底读取管理员账号自身数据、mock 数据或旧接口数据。
- 正常账号数是管理员专属指标，必须来源于真实管理员账号列表筛选契约，即 `GET /api/v1/admin/accounts?page=1&page_size=1&status=active&lite=true` 的分页 `total`，以匹配后台账号筛选“正常”的口径；不得使用 `/api/v1/admin/dashboard/stats` 的 `normal_accounts` 字段冒充该指标，因为该字段会包含限流、临时不可调度等非正常运行态账号。
- 管理员模式不得显示所选用户实时 RPM，除非上游提供并经真实探测确认了按用户 ID 过滤的实时 RPM 契约。
- 读取本机 Keychain 凭据做真实 API 探测时，不得在日志、终端输出、报告或提交内容中显示 token 全文或任何片段。

## 界面约束

- 菜单栏文字必须设置长度上限，过长时在状态栏中截断，并把完整内容保留在 tooltip 或详情面板中，避免遮挡系统菜单栏。
- 菜单栏状态项采用固定宽度的上下双栏布局；所有已启用栏目必须常驻显示，统一使用同一种分割符，避免内容变化造成宽度抖动。
- 菜单栏不得使用 `--` 作为常规占位；普通用户不可用功能必须在设置入口屏蔽，不得让用户开启后再显示不可用占位。
- 菜单栏输入价格和输出价格的上排值不得再额外添加 `i` / `o` 前缀；输入输出语义由下排 `In` / `Out` 标签表达。
- 菜单栏模型名必须优先使用可读短名，避免固定宽度内只剩省略号而无法识别模型来源。
- 发布前需要在本机临时安装目录运行新构建的 App 做真实验证，不得覆盖或替换正式已安装版本；用户正式升级路径仍应通过软件内“检查更新”完成。

## Codex 任务监控约束

- 本项目只监控 Codex 任务状态，不作为 Codex 客户端，不控制 Codex，不使用 Codex App Server。
- 本地和远端 Codex 节点的任务身份必须通过 Codex hooks 精确到 `session_id` / `turn_id`；不得用网关并发、请求时间或 User-Agent 模糊推断具体 Codex 会话或 turn。
- Codex hooks 配置必须使用用户级 Codex 配置目录，并优先读取节点环境中的 `CODEX_HOME`；未设置时才使用该节点用户 home 下的 `.codex`。
- 本机与远端节点统一通过 App 内置 `127.0.0.1:<local_port>` HTTP receiver 接收 hook events；远端节点必须通过 SSH remote forwarding 访问远端回环端口后转回本机 receiver，不暴露公网 hook 入口。
- App 允许在用户确认后通过 SSH 对远端节点安装 hook sender、写入节点配置、备份并修改用户级 Codex `config.toml`、启动和验证 SSH remote forwarding。
- 修改用户级 Codex `config.toml` 时必须原位保留 Codex 自身生成的 `[hooks.state]` 和 `trusted_hash` 状态；不得删除、重排或伪造 trust 状态，只有本项目管理的 hook handler 可以被替换。
- Codex 节点 ID 必须使用文件名安全的 ASCII 字符，并且节点配置文件必须按 `codex-hook-node-<node_id>.json` 独立落盘；不得让多个节点共享自动生成的固定 `codex-hook-node.json` 配置路径。
- Codex hook sender 只能发送监控事件，不得输出会改变 Codex 行为的控制 JSON，不得执行 Codex 控制动作。
- 网关数据只能补充请求、费用、Token、User-Agent、错误和网关负载等信息，不得冒充 Codex `session_id` / `turn_id` 精确状态来源。
- 若旧状态栏并发监控与 hooks 精确任务状态重复，应删除或迁移旧状态栏项，不保留并行实现。

## 本机验证约束

- 本仓库 SwiftPM 命令必须串行执行；不要并行运行多个 `swift test`、`swift build` 或 SwiftPM 相关命令，避免 `.build/.../build.db` 锁冲突。
- 本环境中 SwiftPM、Clang 模块缓存或发布脚本若因沙箱用户缓存不可写失败，且已有同类失败证据时，不要在沙箱中反复重跑同类 `swift test`、`swift build`、打包或发布校验命令；应直接请求真实本机上下文执行，并在交付中说明这是权限环境问题。

## 发布与凭据约束

- 当前 GitHub 分发默认使用 ad-hoc 签名，且本机无稳定 Developer ID 签名身份；不得再把默认 token 存储设计依赖 macOS Keychain ACL 的“始终允许”，因为 ad-hoc `cdhash` 每次重新打包都会变化并导致重复授权提示。
- 默认 token 存储应使用 Application Support 下当前用户私有凭据文件；旧 Keychain 项只允许无 UI 读取迁移，不得触发系统密码框作为常规读取路径。

## 约束维护

- 当重复实践或用户明确反馈形成新的长期项目规则时，更新本文件。
- 修改约束前必须完整读取本文件，避免新增规则与现有规则矛盾。
- 约束应保持具体、当前、可执行。发现过期约束时应修订或删除，不得累积互相冲突的记录。
