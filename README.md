# pi-skills

**验证优先的 agent 技能集**：在说"它工作了"之前，先证明它真的工作。
可用于任何语言、任何引擎。附带一份 Godot 4.x 实战手册。

包含两个技能：

| 技能 | 用途 |
|---|---|
| [`verification`](skills/verification/SKILL.md) | 写/审测试、验证修复、做基准、调试静默失败、报告完成度 |
| [`godot`](skills/godot/SKILL.md) | Godot 4.x：无头测试、物理/导航/骨骼/蒙皮/粒子/音频、联机、导出 |

核心内容（`verification`）：

- **六条硬规则**：双观察面、假信号优先、探针优先、对照必须能失败、排空后再断言、量化门槛
- **假信号清单**（`references/false-signals.md`）：执行类 / 度量类 / 副作用类 / 语义类，每类给识别与验证手法
- **`templates/test_runner.sh`**：语言无关的执行器 —— 超时、挂死检测、错误模式 grep、退出码
- **`templates/playbook.md`**：证据库骨架，含「未解决」字段与写作约定

## 安装

**只想要验证技能？** 用单技能包（不夹带 Godot 手册）：

```bash
pi install git:github.com/CooCoode/pi-verification@v0.1.0
```

### pi（合集包：两个技能都要）

```bash
pi install git:github.com/CooCoode/pi-skills@v0.1.1
```

只装合集但只启用其中一个：在 `~/.pi/agent/settings.json` 里把包写成对象形式，
用 `+路径` / `-路径` 过滤：

```json
{ "packages": [ { "source": "git:github.com/CooCoode/pi-skills@v0.1.1",
                  "skills": ["+./skills/verification"] } ] }
```

也可以只用一次、不写配置：

```bash
pi -e git:github.com/CooCoode/pi-skills@v0.1.1
```

装完在会话里 `/skill:verification` 或 `/skill:godot` 可直接强制加载；
平时它们会在相关任务中出现（skill 描述参与路由）。

### Claude Code / Cursor / 其他 Agent Skills 客户端

本包遵循 [Agent Skills 规范](https://agentskills.io/specification)，`SKILL.md` 可直接复用：

```bash
git clone https://github.com/CooCoode/pi-skills
cp -R pi-skills/skills/verification ~/.claude/skills/     # Claude Code
cp -R pi-skills/skills/godot        ~/.claude/skills/
# 或项目级：cp -R pi-skills/skills/* <repo>/.agents/skills/
```

### 只想要执行器 / 模板（不用 agent）

```bash
curl -O https://raw.githubusercontent.com/CooCoode/pi-skills/v0.1.0/skills/verification/templates/test_runner.sh
chmod +x test_runner.sh

# 用法：按 "名称|命令" 传入用例
./test_runner.sh "unit|pytest -q tests/unit" "e2e|npm run e2e"
# 或从文件读：每行 "名称|命令"
./test_runner.sh -f targets.txt
# 环境变量：TIMEOUT=180（默认）、ERR_PATTERN="..."、QUIET=1
```

## 为什么需要它

大多数"测试通过"是假的：框架吞掉错误、退出码为 0、指标动了但内容错、
工具返回 success 但副作用没发生、基准被编译器优化掉。这些在真实项目里反复出现，
而且**没有任何框架会提醒你**。

`test_runner.sh` 只解决其中最常见的三种（退出码、错误日志、挂死），
`references/false-signals.md` 负责让人意识到剩下的。

## 自测（本包自己也要被验证）

```bash
npm test          # 等价于 bash scripts/self_test.sh
```

它会用四种用例（通过 / 非零退出 / 只打错误日志 / 挂死）检验 `test_runner.sh` 的判定是否正确。
**这个自测抓到过一个真实缺陷**：默认错误模式漏了 `^ERROR:`，导致"打印 ERROR 却退出 0"的
用例被误判为通过。

## Godot 手册

`skills/godot/references/GODOT_PLAYBOOK.md`（33 节）来自两个真实工程的全部实测结论：
每条都是「结论 + 报错原文 + 实测数字 + 走过的弯路」，并显式标注 3 条**未解决**项。

## 版本与兼容

- 技能是**指令**，不是代码；行为会随宿主模型变化。请固定版本使用（git tag / 精确版本号）。
- 包内只有纯 Markdown 与一个 Bash 脚本，没有扩展代码，不加 `pi` 也能安全阅读与审计。
- 许可：MIT。
