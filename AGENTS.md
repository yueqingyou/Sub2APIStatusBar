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
- 正常账号数是管理员专属指标，必须遍历 `GET /api/v1/admin/accounts?status=active&lite=true` 的全部分页并排除 `parent_account_id != nil` 的影子账号，以过滤后的账号数作为结果；不得直接使用分页 `total`，也不得使用 `/api/v1/admin/dashboard/stats` 的 `normal_accounts` 字段。
- 账号页、额度聚合和预测只允许使用 `platform=openai && type=oauth && parent_account_id==nil` 的账号；其他平台、其他账号类型和 Spark shadow 均不得显示、计数、采样或参与额度与标准价值计算。
- OpenAI OAuth 官方额度以 TokenRouter 返回的五小时、七天用量百分比和重置时间为准；价值统一使用 `standard_cost`，本地预测不得覆盖或改写 TokenRouter 当前值。
- 管理员模式不得显示所选用户实时 RPM，除非上游提供并经真实探测确认了按用户 ID 过滤的实时 RPM 契约。
- 读取本机 Keychain 凭据做真实 API 探测时，不得在日志、终端输出、报告或提交内容中显示 token 全文或任何片段。

## 界面约束

- 菜单栏文字必须设置长度上限，过长时在状态栏中截断，并把完整内容保留在 tooltip 或详情面板中，避免遮挡系统菜单栏。
- 菜单栏状态项采用固定高度的上下双栏布局；所有已启用栏目必须常驻显示并统一使用同一种分割符。栏目宽度应根据实际文本测量结果在明确上下限内分档调整，减少短值的无效留白，同时避免逐字符变化造成宽度抖动。
- 菜单栏不得使用 `--` 作为常规占位；普通用户不可用功能必须在设置入口屏蔽，不得让用户开启后再显示不可用占位。
- 菜单栏输入价格和输出价格的上排值不得再额外添加 `i` / `o` 前缀；输入输出语义由下排 `In` / `Out` 标签表达。
- 菜单栏模型名必须优先使用可读名称，并设置合理宽度上限；不得为了压缩宽度把可识别的完整名称缩成含义不明的片段。
- 用户界面不得暴露父账号、影子账号或额度筛选等内部术语；OpenAI OAuth 账号空状态使用“暂无 OpenAI OAuth 账号”，不得添加解释性注解。
- OpenAI OAuth 账号页的剩余账号当量使用百分比，可超过 `100%`；额度行只显示已用百分比，重置倒计时显示天、小时等明确时长，并显示套餐到期时间和已启用的隐私状态。
- 发布前需要在本机临时安装目录运行新构建的 App 做真实验证，不得覆盖或替换正式已安装版本；正式 CI 产物还必须在最低支持的 Intel macOS 上完成首次刷新并持续运行至少 30 秒，确认没有新增崩溃报告后才能推送版本标签。用户正式升级路径仍应通过软件内“检查更新”完成。

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
- 任何修改仓库代码的任务，交付前都必须在全部代码改动完成后串行运行 `VERSION=<当前版本> ./scripts/build-app.sh`，生成可直接启动的 `Sub2APIStatusBar.app`；`swift test`、`swift build`、静态检查或此前生成的 App 都不能替代本轮最终 `.app` 编译。
- `.app` 编译成功后必须核对 bundle 元数据、可执行文件架构和签名状态，并在交付中提供本轮新生成 App bundle 的绝对路径供用户本地测试；不得只提供 SwiftPM 裸可执行文件路径，也不得覆盖或替换正式安装版本。
- 本环境中 SwiftPM、Clang 模块缓存或发布脚本若因沙箱用户缓存不可写失败，且已有同类失败证据时，不要在沙箱中反复重跑同类 `swift test`、`swift build`、打包或发布校验命令；应直接请求真实本机上下文执行，并在交付中说明这是权限环境问题。

## 发布与凭据约束

- 当前 GitHub 分发默认使用 ad-hoc 签名，且本机无稳定 Developer ID 签名身份；不得再把默认 token 存储设计依赖 macOS Keychain ACL 的“始终允许”，因为 ad-hoc `cdhash` 每次重新打包都会变化并导致重复授权提示。
- 默认 token 存储应使用 Application Support 下当前用户私有凭据文件；旧 Keychain 项只允许无 UI 读取迁移，不得触发系统密码框作为常规读取路径。
- 正式版本标签必须由 GitHub Actions 自动构建、校验并发布 `x86_64`、`arm64` 和 Universal 2 三类资产；本地手动创建 GitHub Release 只作为 CI 故障恢复手段，不得作为默认发布路径。
- 为兼容尚未识别架构的旧版 updater，CI 必须额外复制一份名称按字典序排在单架构资产之前、内容与 Universal 2 完全相同的兼容 ZIP，并在公开 Release 前断言该兼容包是 API 返回的第一份 macOS ZIP、两份资产 digest 一致且资产数量准确。
- GitHub 草稿 Release 刚创建时，草稿 ID、资产列表和 digest 可能短暂不可见；CI 必须在有限超时内轮询草稿 ID，并基于同一份 release API 快照校验资产，避免把最终一致性延迟误判为发布失败。
- App 自动更新必须优先选择与当前进程架构一致的资产，其次选择 Universal 2，再兼容旧版无架构资产；不得回退安装另一种不兼容的单架构资产，并且替换前必须校验下载 App 的真实 Mach-O 架构。

## 约束维护

- 当重复实践或用户明确反馈形成新的长期项目规则时，更新本文件。
- 修改约束前必须完整读取本文件，避免新增规则与现有规则矛盾。
- 约束应保持具体、当前、可执行。发现过期约束时应修订或删除，不得累积互相冲突的记录。
