---
name: godot
description: Build, test, debug and export Godot 4.x games. Use whenever a task involves Godot projects (project.godot, .tscn, .gd), headless scene or script tests, physics/navigation/skinning/particles/audio in Godot, GDExtension, or exporting to macOS/Web/Android/iOS.
---

# Godot 4.x 实战技能

证据库在本包 `references/GODOT_PLAYBOOK.md`（33 节：每条 = 结论 + 报错原文 + 实测数字 + 走过的弯路）。
遇到不确定的细节先读它，里面还标了 3 条**未解决**项。

> 版本说明：以下结论验证于 **Godot 4.7.2-stable**（macOS arm64）。
> 换大版本后请先重跑本文的「环境探测」和「最小验证回路」，不要默认成立。

## 0. 环境探测（拿到项目后第一件事，别猜路径）

```bash
godot --version                     # 期望 4.x；输出形如 4.7.2.stable.official.<hash>
which godot                         # macOS 常见为 /Applications/Godot.app/Contents/MacOS/Godot 的软链
uname -m                            # arm64 / x86_64，影响导出切片
sw_vers -productVersion             # 或 lsb_release -a

# 导出模板是否已装（缺失会导致所有导出直接失败）
ls ~/Library/Application\ Support/Godot/export_templates/   # macOS
ls ~/.local/share/godot/export_templates/                    # Linux
```

最小验证回路（30 秒，能判定"这个工程+这套工具链可用"）：

```bash
godot --headless --editor --quit                          # 建/重建导入缓存
godot --headless --path . res://某个场景.tscn                # 能跑起来就说明资源/脚本没坏
```

## 0.1 必须先知道的 8 条（每条都是踩过的坑）

1. **两种无头模式差别巨大**
   - `godot --headless --path . --script x.gd`（脚本 `extends SceneTree`）：**没有 autoload**，
     脚本里引用自动加载单例的全局标识符**编译期就不存在**。适合纯逻辑测试。
   - `godot --headless --path . res://tests/x.tscn`（场景 + `extends Node`）：autoload 正常。
     需要单例/节点/物理的测试**必须**用这个。
2. **项目没有主场景时**，`godot --headless --quit` / `--quit-after N` 会报错并**挂死不退出**。
   建缓存用 `--editor --quit`。
3. **`SceneTree.physics_frame` 先于 `Node._physics_process` 发出**：`await` 一帧读到的是"处理前"，
   要看结果得等两帧。headless 仍按 60 Hz 节流（约 16 ms/帧）。
4. **脚本错误不一定改变退出码**：测试执行器必须额外 grep 错误模式。
   注意 Godot 会打 `ERROR:` 行但退出 0（见 `verification` 技能里的假信号清单）。
5. **导出 macOS(arm64/universal) 与 Android 前必须开**
   `rendering/textures/vram_compression/import_etc2_astc=true`，否则直接报错。
   `--export-release` 需要发布密钥库；只想验证链路用 `--export-debug`。
6. **手改 `project.godot` 后一定 grep 验证**：编辑器会重排/剪枝（默认值段落会被删掉），
   文本替换可能静默失败。锚点别选可能被剪掉的段落，追加到文件末尾最稳。
7. **用脚本往 GDScript 里注入中文时，双引号字符串里不能再写双引号** —— 会截断字符串，
   而解析失败后进程会**挂住**，看起来像死循环。
8. **GUI 编辑器会重写文件**（槽位 ID、资源格式规范化）：动编辑器前先 commit，事后看 diff。

## 1. 常用命令

```bash
godot --path .                                  # 跑主场景（窗口）
godot --headless --editor --quit                # 重建导入缓存
godot --headless --path . res://tests/x.tscn    # 跑指定场景（集成测试）
godot --headless --path . --script tests/x.gd    # 纯逻辑测试（无 autoload）
godot --headless --path . --export-release "macOS" build/macos/App.zip
godot --headless --path . --export-release "Web"   build/web/index.html
godot --headless --path . --export-debug   "Android" build/android/app.apk
```

macOS 上 **F5 是媒体键**，触发不了"运行项目"；用编辑器右上角 ▶ 或菜单 项目 → 运行。

## 2. 写测试的套路

- 场景模式：根节点 `extends Node`，`_ready()` 里 `await` 断言，末尾 `get_tree().quit(0/1)`。
- 等的写法：`for i in range(90): await get_tree().physics_frame`（90 帧 ≈ 1.5 s）。
- 模拟输入：`Input.action_press/release("jump")` 或 `Input.parse_input_event(InputEventAction)`；
  **按下后要等 2 帧**才看得到物理结果。
- 断言要可证伪：带实测值和阈值，不要 `_check(true, "")`。
- 用 `verification` 技能的 `templates/test_runner.sh` 包装（退出码 + 错误模式 + 挂死检测）。

## 3. API 语义备忘（实测，容易记反的）

| 主题 | 结论 |
|---|---|
| 物理层 | 判定靠 `collision_layer/mask`；同几何不同 layer → 一个穿过一个挡住 |
| `ShapeCast3D` | **碰到第一个就停**，只报最近命中；要"一次拿全部重叠"用 `PhysicsDirectSpaceState3D.intersect_shape()` |
| `move_and_collide()` | 返回 `KinematicCollision3D`（法线 / 碰撞体 / 行进距离） |
| 导航 | 多边形**只有共享完全一致的边才连通**（部分重叠不连）；地图异步同步，要**轮询到能查到路径**；诊断用 `map_get_closest_point()` |
| 蒙皮 | 手搓 `ARRAY_BONES`(每顶点 4 索引) + `ARRAY_WEIGHTS`(4 权重) + `Skin.set_bind_name()` + `MeshInstance3D.skeleton`；索引绕序反了会被背面剔除（图元数正常但看不见）→ 用 `cull_mode = CULL_DISABLED` 判断 |
| 骨骼 | 动画轨道路径 `Skeleton3D:bones/N/rotation`（四元数）；绕 +X 转 90° 是 `+Y → +Z` |
| 粒子 | `color_ramp` 要 **Texture2D**（用 `GradientTexture1D`）；场景**没有相机就什么都不画**，图元数恒 0 |
| 音频 | `AudioStreamPlayer2D` 缺 **Camera2D 监听者会完全不发声**（总线峰值恒 -200，别误判成驱动问题） |
| 渲染器 | GL 兼容下 SSIL/SSR 被禁用并警告；headless 两者都是 dummy → 渲染器对比**必须开窗口** |
| Theme | 优先级 节点 override > 类型变体 > 主题类型 > 默认；查变体用 `get_type_variation_base()`（**没有** `has_type_variation()`） |
| TileMapLayer | `TileSet.add_source()` 必须早于给 `TileData` 加碰撞多边形；坐标用 `to_local` + `local_to_map`（脚踩边界要往下取 1px） |
| 联机 | `multiplayer` 是 **Node 属性**（`SceneTree` 上没有）；两端节点路径必须一致且**根节点同名**；`MultiplayerSynchronizer` **两端都要创建** |

## 4. 联网/实时同步的经验数

- 5 Hz 同步下 raw 单帧跳变 0.267 → 两点前向插值后 0.109（延迟一个同步间隔）
- 30% 丢包 + 60 ms：只发当前输入误差 0.650 → 输入冗余+去重 0.063 → 客户端预测 0.000
- 回滚重放的**单次修正量上限 ≈ (延迟 + 抖动) × 输入变化幅度**；回滚**修不了丢包**（要靠冗余/ack）
- 双进程测试前先清理残留进程（端口是全局状态），否则报 `Couldn't create an ENet host`

## 5. 导出与工具链（探测而非假设）

```bash
# Android 需要 JDK + SDK 路径写进编辑器设置（export/android/java_sdk_path / android_sdk_path）
/usr/libexec/java_home -V 2>/dev/null || update-alternatives --list java   # 找 JDK
echo "$ANDROID_HOME" ; sdkmanager --list_installed 2>/dev/null | head      # 找 SDK
#   需要 platform-tools / build-tools / platforms；licenses 先 `yes | sdkmanager --licenses`
#   macOS 模拟器跑 APK 时，启动入口是 com.godot.game.GodotAppLauncher（GodotApp 未导出）

# GDExtension：godot-cpp 需显式 api_version（新版本不再分 4.x 分支）
git clone --depth 1 https://github.com/godotengine/godot-cpp.git
(cd godot-cpp && scons platform=macos arch=arm64 target=template_debug api_version=<你的版本前两位> -j8)
```

- 下载 GitHub release 资源慢时走代理：`https_proxy=<你的代理>`（示例：`http://127.0.0.1:7890`）。
- Linux 装 JDK 一般无需 sudo 的方式各发行版不同；macOS `brew install --cask temurin` 需要 sudo，
  没有密码时用 `brew install openjdk@21`（keg-only）。

## 6. 参考工程

| 工程 | 内容 |
|---|---|
| `texas-holdem` | 完整游戏：规则引擎 + 牌力评估 + AI + UI + 测试 + 双平台发布包 |
| `godot-lab` | 13 个能力实验（物理/导航/3D/骨骼/蒙皮/粒子/音频/联机/Theme/GDExtension），185 项断言 |

本包 `references/GODOT_PLAYBOOK.md` 是这两个工程的结论汇总，可直接当"团队内部规范"的起点。
