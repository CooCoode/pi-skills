# Godot 实战 Playbook（全部经过实测）

> 本文件只记录**我亲手跑通或踩过坑**的结论，每条都附判断依据。
> 环境：macOS 15.8.2 / Godot 4.7.2-stable（Homebrew cask）/ Apple M4。

---

## 1. 两种无头（headless）运行模式，差别很大

| 方式 | autoload 是否存在 | 适用场景 |
|---|---|---|
| `godot --headless --path . --script tests/x.gd`（脚本 `extends SceneTree`） | **不存在**，连 `GameState` 这种全局标识符都会**编译失败**（`Identifier not found`） | 纯逻辑测试（牌力评估、规则引擎） |
| `godot --headless --path . res://tests/x.tscn`（场景模块 + `extends Node`） | 正常存在 | 需要单例、节点、物理、UI 的测试 |

实测依据：扑克项目的 `tests/*.gd` 用 `--script` 跑得很好（不碰 autoload）；
本工程的测试一旦引用 `GameState` 就编译报错，改成场景模式后立刻通过。

其它相关命令：

```bash
godot --headless --editor --quit          # 建/重建导入缓存（改了资源后必跑）
godot --headless --path . res://x.tscn    # 跑指定场景
godot --headless --path . --quit-after N  # ⚠️ 项目没定义主场景时会报错并【挂死不退出】
```

## 2. 测试里"时间"和"输入"的坑

- **`SceneTree.physics_frame` 信号在 `Node._physics_process` 之前发出**。
  所以 `await get_tree().physics_frame` 之后读到的还是"本帧处理前"的状态；
  想看某帧的处理结果，必须再等一帧。实测：按下跳跃后等 1 帧 `velocity=(0,0)`，等 2 帧才是 `(0,-520)`。
- 模拟输入有两种：`Input.action_press/release("jump")`（简单直接），
  或 `Input.parse_input_event(InputEventAction)`（走真实输入管线）。两者都能在 headless 下生效。
- **headless 不等于"不限速"**：实测 90 个物理帧耗时 1458 ms ≈ 16.2 ms/帧，仍是 60 Hz 节流。
  写循环等待时按真实时间估算。
- **`SCRIPT ERROR` 不一定改变退出码**，CI/脚本必须额外 grep 输出（否则测试"全绿"其实没跑）。

## 3. 手写 `.tscn`（编辑器保存出来的就是这种文本格式）

```ini
[gd_scene load_steps=13 format=3]

[ext_resource type="Script" path="res://scripts/player.gd" id="2_player"]
[ext_resource type="PackedScene" path="res://scenes/coin.tscn" id="3_coin"]
[ext_resource type="FontFile" path="res://assets/NotoSansSC-Regular.otf" id="6_font"]

[sub_resource type="RectangleShape2D" id="RectangleShape2D_player"]
size = Vector2(32, 48)

[node name="Player" type="CharacterBody2D" parent="."]
position = Vector2(120, 300)
script = ExtResource("2_player")

[node name="CollisionShape2D" type="CollisionShape2D" parent="Player"]
shape = SubResource("RectangleShape2D_player")

[node name="Coin1" parent="Coins" instance=ExtResource("3_coin")]   ; 子场景实例
position = Vector2(300, 430)
```

要点：

- 子场景实例用 `instance=ExtResource("...")`，不需要 `type=`，也支持覆盖 `position` 等属性。
- 主题覆盖写 `theme_override_fonts/font`、`theme_override_font_sizes/font_size`、`theme_override_colors/font_color`。
- 着色器：`[sub_resource type="ShaderMaterial"]` + `shader = ExtResource(...)` + `shader_parameter/名字 = 值`，节点上 `material = SubResource(...)`。
- 动画：`[sub_resource type="Animation"]` 里 `tracks/0/type = "value"`、
  `keys = {"times": PackedFloat32Array(...), "transitions": ..., "update": 0, "values": [...]}`；
  再包一层 `[sub_resource type="AnimationLibrary"]` 的 `_data = {&"pop": SubResource(...)}`，
  节点写 `libraries = {&"": SubResource("AnimationLibrary_main")}`。
- **Godot 4.7 编辑器保存时会为每个节点写 `unique_id=...`**；手写时省略完全没问题（本工程全部手写，编辑器照常打开）。
- 验证一套手写场景是否"编辑器兼容"，三步：`load()` 能拿到 `PackedScene` → `instantiate()` 后断言节点结构 → 用编辑器打开亲眼看。

## 4. 游戏系统要点（都实测过）

- **物理**：`CharacterBody2D` + `velocity` + `move_and_slide()` + `is_on_floor()`；
  地面/墙用 `StaticBody2D` + `RectangleShape2D`。**记得给世界加边界**，
  否则角色会一直往右走出地面掉进虚空（我第一次演示就是这么丢的玩家）。
- **Area2D 拾取**：`body_entered` → 发信号 → 根节点加分/播音效 → `queue_free()`；先 `set_deferred("monitoring", false)` 防重复触发。
- **动画**：`AnimationPlayer` + 信号里 `play("pop")`；track 的 `path` 相对 AnimationPlayer（如 `NodePath("Player/Sprite:scale")`）。
- **音效**：`AudioStreamPlayer` + `.wav`（自动导入，无需手工配置）；
  播放器要挂在**短命节点之外**（金币自己 `queue_free` 会把子节点一起带走，音效被截断）。
- **存档**：`user://` + `ConfigFile`（键值、类型安全）或 `JSON`（可读、跨语言）；
  在 `_exit_tree()` 里存；实际路径用 `ProjectSettings.globalize_path("user://")` 查
  （macOS 上是 `~/Library/Application Support/Godot/app_userdata/<项目名>/`）。
- **着色器**：`shader_type canvas_item;` + `uniform vec4 tint : source_color;` / `uniform float x : hint_range(0,2);`，
  挂到 `ColorRect` 的 `ShaderMaterial` 上；编辑器 2D 视图和运行时都会渲染。
- **自动加载**：`project.godot` 里 `[autoload]` 段 `GameState="*res://scripts/game_state.gd"`，
  全局以 `GameState` 访问；注意它**只在正常启动/场景模式测试里存在**。

## 5. 联机（ENet + RPC）

```gdscript
var peer := ENetMultiplayerPeer.new()
peer.create_server(9876, 4)            # 服务端
peer.create_client("127.0.0.1", 9876)  # 客户端
multiplayer.multiplayer_peer = peer    # 注意：multiplayer 是 Node 的属性
```

- **`SceneTree` 上没有 `multiplayer` 属性**（写 `get_tree().multiplayer` 会直接报错），要用节点自己的 `multiplayer`。
- RPC 方法：`@rpc("any_peer", "call_remote", "reliable")`，调用 `某节点.方法.rpc_id(1, 参数)`。
- **两端节点路径必须一致**（都叫 `/root/Net`），否则 RPC 找不到目标。
- 双进程实测：服务端日志出现 `收到来自 <id> 的 ping`，客户端拿到 `pong:hello`，往返成功。

## 6. Godot MCP 工具链（@coding-solo/godot-mcp）

14 个工具：`launch_editor / run_project / get_debug_output / stop_project / get_godot_version /
list_projects / get_project_info / create_scene / add_node / load_sprite /
export_mesh_library / save_scene / get_uid / update_project_uids`。

- 需要 `GODOT_PATH` 环境变量；协议是标准 stdio JSON-RPC，可以脚本化调用。
- **真能写文件**：`create_scene` + `add_node` 生成的 tscn 会被写出（且带 4.7 的 `unique_id`）。
- **`launch_editor` 返回值不可信**：它回 `success`，但实测没有编辑器进程出现。
  要用 `ps` / 窗口列表核实；需要确定性就用 CLI `godot -e --path . <scene>`。

## 7. 导出与发布

```bash
godot --headless --path . --export-release "macOS" build/macos/App.zip
godot --headless --path . --export-release "Web"   build/web/index.html
godot --headless --path . --export-debug   "Android" build/android/app.apk
```

- 模板目录：`~/Library/Application Support/Godot/export_templates/4.7.2.stable/`（从 `.tpz` 解压得到）。
- **必须先开 `rendering/textures/vram_compression/import_etc2_astc=true`**，
  否则 macOS（universal/arm64）和 Android 导出都会失败，报错原文："禁用 ETC2 ASTC 纹理格式时无法为 universal 和 arm64 进行导出"。
  这是**两次独立踩到的同一个坑**（扑克工程、本工程）。
- `--export-release` 需要**发布密钥库**，没有就报"找不到发布密钥库，无法导出"；
  只是想验证链路就用 `--export-debug`（自动用调试密钥库，`apksigner` 会显示 `CN=Godot` 签名）。
- Android 还需要：`export/android/java_sdk_path` 与 `export/android/android_sdk_path`
  （编辑器设置文件 `~/Library/Application Support/Godot/editor_settings-4.7.tres`，可直接改文本）。
- 无 sudo 装 JDK：`brew install openjdk@21`（keg-only，路径 `/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home`）。
  `brew install --cask temurin` 需要 sudo 装 pkg，没有密码时会失败。
- Android SDK：`brew install --cask android-commandlinetools`（无 sudo），
  然后 `yes | sdkmanager --licenses` + `sdkmanager "platform-tools" "build-tools;35.0.0" "platforms;android-35"`。
- **产物必须验证**，不能只看"导出没报错"：APK 用 `apksigner verify --print-certs`（要设 `JAVA_HOME`）、
  解压确认 `lib/arm64-v8a/libgodot_android.so`；桌面/Web 则解压后真跑一遍 + 截图。

## 8. macOS 层面的三个坑（与 Godot 无关但会挡路）

- **TCC 权限**：进程读 `~/Downloads` 会弹「想访问下载文件夹」。用 `/tmp` 或工作区目录可完全绕开。
- **F5 是媒体键**：在 Mac 上按 F5 不会触发"运行项目"，要用编辑器右上角 ▶（或菜单 项目 → 运行）。
- **`osascript` 控制 Chrome 会卡住**（Apple Events 权限），改用 `cmd+w` 之类的快捷键。

## 9. 性能

- 无头模式仍按 60 Hz 节流，用它测"每帧耗时"意义有限；
  真要看帧时间/内存/对象数，用编辑器底部 **调试器 → 分析器（Profiler）**，
  或 `--remote-debug` 连上后在"监视/性能"面板看。
- 纯逻辑热点（如牌力评估）用 `Time.get_ticks_usec()` 包循环做微基准更直接。

---

## 10. 物理层与碰撞掩码（第二轮实测）

目标：验证"同几何体、不同 layer"的行为差异。

```ini
[node name="Player" type="CharacterBody2D" parent="."]
collision_layer = 1
collision_mask = 1

[node name="GhostBarrier" type="StaticBody2D" parent="Walls"]
collision_layer = 2      # 玩家 mask=1 → 看不见 → 直接穿过
collision_mask = 0

[node name="SolidBarrier" type="StaticBody2D" parent="Walls"]
collision_layer = 1      # 玩家 mask 命中 → 挡住
```

实测：同样 16×200 的两道墙，玩家从 x=350 向右跑，**穿过** layer=2 的（到 x=470），
**被挡在** layer=1 的（x=536，正好是 560-8-16）。结论：**精确判定靠 layer/mask，不靠距离判断**。

## 11. `@export` 与 `collision_*` 都能在 `.tscn` 里直接覆盖

`.tscn` 里写 `speed = 400.0`，运行时 `player.speed == 400.0` 断言通过。
这意味着**同一份脚本 + 不同场景 = 不同参数**，不必为每个变体写代码。

## 12. 性能剖析（真实数字，不是"能跑就行"）

`Performance.get_monitor()` 采样 300 帧（场景 = 本工程的 platformer）：

| 指标 | 数值 |
|---|---|
| Draw Calls | 13（恒定） |
| 图元数 | 94 |
| Node 数 | 41 |
| Resource 数 | 18 |
| 静态内存 | 39.8 MB |
| 物理帧耗时 | 平均 0.45 ms |
| FPS | 95~117（窗口模式未开垂直同步） |

微基准（`Time.get_ticks_usec`）：

- 100 万次整数取模：**45.6 ms**（≈45.6 ns/次）
- 1000 个子场景：`instantiate` **5.1 ms**（5 µs/个）、`add_child` **121 ms**（121 µs/个）、`queue_free` 调用仅 0.2 ms
- 10000 次 `Node2D.new()` + 设属性 + `free()`：3.8 ms（0.38 µs/次）

**结论：贵的是"进树"（add_child ≈ instantiate 的 24 倍），不是对象分配。**
批量生成东西时要考虑对象池/一次性批量入树。

坑：`TIME_PROCESS` 监视器读到的不是纯逻辑耗时（含帧间等待），
要精确定位热点还是得用编辑器 **调试器 → 分析器**；本例仅用于量级判断。

## 13. 场景同步联机（MultiplayerSpawner + MultiplayerSynchronizer）

```gdscript
# 两端共建同一棵树（脚本里用 class_name NetWorld 复用）
spawner.spawn_path = NodePath("..")
spawner.spawn_function = func(data): ...   # 两端必须都设置同一个函数

var cfg := SceneReplicationConfig.new()
cfg.add_property(^".:position")            # 属性路径相对 Synchronizer 的父节点
sync.replication_config = cfg
```

实测（两个 headless 进程）：

```
[SERVER] 节点路径 = /root/MpRoot/World/SyncedToken
[CLIENT] ✅ Spawner 复制的节点已出现：Token_1 @ (123.0, 45.0)
[CLIENT] ✅ 属性同步到位：SyncedToken.x = 777.0
```

**最关键的坑：两端场景根节点必须同名。** 复制/RPC 用的是**绝对节点路径**
（`/root/<场景根>/...`），服务端叫 `MpServer`、客户端叫 `MpClient` 时永远对不上。
本工程统一改成 `MpRoot` 后立刻通过。

## 14. TileMapLayer（Godot 4.3+ 取代 TileMap）

运行时全代码生成图集 + 瓦片（不依赖美术资源）：

```gdscript
var ts := TileSet.new()
ts.tile_size = Vector2i(16, 16)
ts.add_physics_layer(0)                     # ① 先加物理层
var src := TileSetAtlasSource.new()
src.texture = ImageTexture.create_from_image(img)   # Image 直接画出来的图集
src.texture_region_size = Vector2i(16, 16)
ts.add_source(src, 0)                       # ② 再挂到 TileSet（顺序很重要！）
src.create_tile(Vector2i(i, 0))
src.get_tile_data(Vector2i(i, 0), 0).add_collision_polygon(0)   # ③ 这时才有物理层可用
...
var layer := TileMapLayer.new()
layer.tile_set = ts
layer.set_cell(Vector2i(x, y), 0, Vector2i(atlas_x, 0))
```

- **坑 1**：`TileData.add_collision_polygon(0)` 在 `add_source` **之前**调用会报
  `Index p_layer_id = 0 is out of bounds (physics.size() = 0)` ——
  TileData 只有在挂到 TileSet 之后才知道有哪些物理层。
- **坑 2**：坐标换算 `layer.to_local(global_pos)` → `layer.local_to_map(local)`；
  角色停在瓦片顶面时脚底正好在边界上（y 为整数），做"脚下是哪格"判断要往下取 1px，
  否则会映射到上一格（实测 y=-0.018 → 格 -1）。
- 碰撞多边形坐标是**以瓦片中心为原点**的局部坐标（16×16 瓦片 → ±8）。
- 验证方式：角色自由落体后 `is_on_floor()` 为真、静止高度 = 瓦片顶面 − 半高（断言通过）。

## 15. 在 Android 模拟器上真跑 APK（完整链路）

```bash
brew install --cask android-commandlinetools          # 无 sudo
yes | sdkmanager --licenses
sdkmanager "platform-tools" "build-tools;35.0.0" "platforms;android-35" \
           "emulator" "system-images;android-35;google_apis;arm64-v8a"
avdmanager create avd -n lab35 -k "system-images;android-35;google_apis;arm64-v8a" -d pixel_6
emulator -avd lab35 -no-window -no-audio -no-snapshot -no-boot-anim -gpu swiftshader_indirect &
adb wait-for-device && adb shell getprop sys.boot_completed      # 就绪后为 1（本次约 15 秒）
adb install -r build/android/godot-lab.apk
adb shell cmd package resolve-activity --brief com.example.godotlab   # 查真实入口！
adb shell am start -W -n com.example.godotlab/com.godot.game.GodotAppLauncher
adb exec-out screencap -p > shot.png
```

- **坑 1**：`am start -n <包>/com.godot.game.GodotApp` 会报
  `SecurityException: not exported from uid` —— Godot 4 导出的入口是
  **`com.godot.game.GodotAppLauncher`**（`GodotApp` 是内部 Activity，未导出）。
- **坑 2**：首次全屏运行会弹系统提示「Viewing full screen」，
  用 `adb shell settings put secure immersive_mode_confirmations confirmed` 关掉。
- 实测结果：APK 装得上、起得来，logcat 里能看到
  `Godot Engine v4.7.2.stable.official` + `OpenGL ES 3.1 (ANGLE/SwiftShader)`；
  截图里着色器、中文字体、瓦片/碰撞、HUD 全部正常。
- 模拟器是软件渲染（SwiftShader），帧率不代表真机。

## 16. iOS 导出：真实门槛

- 不填 Team ID 直接报：**「未指定 App Store 团队 ID」**，导出中止。
- 填一个占位 Team ID 后**能导出完整 Xcode 工程**：
  `GodotLab.xcodeproj` + `GodotLab.pck` + `GodotLab.xcframework`（含 `ios-arm64` 与
  `ios-arm64_x86_64-simulator` 两个切片）+ `MoltenVK.xcframework`。
- 用 `xcodebuild -target GodotLab -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO` 编译，
  **链接失败**：`Undefined symbols for architecture arm64: "_main"`。
  工程里只有 `dummy.swift`，Swift 入口没被正确纳入 —— 这条**未解决**，
  需要真实 Team ID + 用 scheme 构建再试。真机运行必须有开发者证书与 provisioning profile。

**结论：iOS 这条路的唯一硬门槛是 Apple 开发者身份，不是技术配置。**

## 17. 场景继承（inherited scene）

```ini
# derived_actor.tscn：根节点直接 instance 基场景，再覆盖属性/追加子节点
[gd_scene load_steps=3 format=3]
[ext_resource type="PackedScene" path="res://scenes/base_actor.tscn" id="1_base"]
[ext_resource type="Resource" path="res://assets/hero.tres" id="2_cfg"]

[node name="BaseActor" instance=ExtResource("1_base")]
speed = 250.0
config = ExtResource("2_cfg")

[node name="Flame" type="Polygon2D" parent="."]
position = Vector2(0, -20)
```

实测：基场景 `speed=100`、继承场景 `speed=250`，**基场景不受影响**；
基场景的 `Body` 子节点与多边形原样继承，`Flame` 是新增的。
这是"一份逻辑 + 多个变体"的正规做法，比复制粘贴场景强得多。

## 18. 自定义 Resource 当数据资产

```gdscript
class_name ActorConfig
extends Resource
@export var display_name: String = ""
@export var speed: float = 100.0
@export var tags: PackedStringArray = []
```

```ini
[gd_resource type="Resource" script_class="ActorConfig" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/actor_config.gd" id="1_cfg"]
[resource]
script = ExtResource("1_cfg")
display_name = "Hero"
speed = 320.0
tags = PackedStringArray("player", "fast")
```

`load("res://assets/hero.tres")` 直接得到带类型的对象，也能被 `.tscn` 用 `ExtResource` 引用。
注意 `.tres` 头部要写 `script_class=`（编辑器新建资源时会写），手写漏了通常也能加载，
但类型提示/检查会弱一些。

## 19. UI 容器布局（响应式的真相）

- 容器（VBox/HBox/GridContainer…）**默认只按孩子的最小尺寸排列，剩余空间留白**。
  想让子节点分掉剩余空间，必须设 `size_flags_horizontal = Control.SIZE_EXPAND_FILL`。
  实测：两个空 Button 默认各 8px 宽；设 EXPAND_FILL 后两等分 400px。
- 锚点预设 `set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT / PRESET_BOTTOM_WIDE)`
  让控件跟随父尺寸。
- 改父 `size` 后容器**自动重排**（实测 400 → 600 后按钮宽度随之变化），
  所以不要手动算坐标 —— 那是 UI 布局最大的返工来源。

## 20. 国际化（CSV → .translation）

1. `translations/strings.csv`，第一行 `keys,en,zh`，其余行是 key 与各语言文本。
2. 导入后 Godot 在**同目录**生成 `strings.en.translation` / `strings.zh.translation`。
3. `project.godot` 里必须登记，否则 `tr()` 原样返回 key：

```ini
[internationalization]

locale/translations=PackedStringArray("res://translations/strings.en.translation", "res://translations/strings.zh.translation")
```

4. `TranslationServer.set_locale("zh")` 后 `tr("HELLO") == "你好"`，带格式化 `tr("COINS") % 5 == "金币 x5"`。

**坑（本轮真实翻车）**：我用文本替换往 `project.godot` 插 `[internationalization]` 段，
锚点选的是 `[physics]` —— 但那段因为全是默认值**已被编辑器剪枝删掉**，
`String.replace` 静默什么都没做，于是翻译一直不生效。
教训：**手改 project.godot 后一定 grep 验证段落真的写进去了**，
锚点不要选可能被剪枝的默认值段落（追加到文件末尾最稳）。

## 21. GDExtension（用 C++ 扩展引擎）

流程（macOS arm64，实测通过）：

```bash
brew install scons                                # SCons 构建系统
git clone --depth 1 https://github.com/godotengine/godot-cpp.git /tmp/godot-cpp
cd /tmp/godot-cpp && scons platform=macos arch=arm64 target=template_debug api_version=4.7 -j8
# 然后在自己的扩展目录 scons platform=macos arch=arm64 target=template_debug api_version=4.7 -j8
```

- **`api_version` 现在是必填**（godot-cpp master 已不再分 4.x 分支，而是内置
  `gdextension/extension_api-4-{3..8}.json`）。漏了会直接报
  `scons: *** 'api_version' must be provided`。指向 4.7 就写 `api_version=4.7`。
- 仓库里只到 `4.5` 分支 + `godot-4.5-stable` 标签；要绑 4.7 就用 `master` + `api_version=4.7`。
- 产物：macOS 下 `env.SharedLibrary("bin/liblabtools.macos.template_debug", ...)`
  生成的是**没有 .dylib 后缀**的 Mach-O dylib（`file` 显示
  `Mach-O 64-bit dynamically linked shared library arm64`），`.gdextension` 里按实际文件名写即可。
- `.gdextension` 必须写 `entry_symbol`（对应 `GDE_EXPORT` 的注册函数名）、
  `compatibility_minimum` 和每个平台的库路径。
- 注册类：`GDREGISTER_CLASS(LabTools)` 必须在 `MODULE_INITIALIZATION_LEVEL_SCENE` 里做。
- 验证：`ClassDB.class_exists("LabTools")` + `ClassDB.instantiate("LabTools")` 后调用方法。

实测收益（500 万次取模循环）：

| 实现 | 耗时 |
|---|---|
| C++（GDExtension） | **2.2 ms** |
| GDScript | 72.1 ms |

**坑：编译器会把基准循环整个优化掉。** 我第一次测得 C++ 0.0 ms —— 因为 `acc` 没被使用。
只写 `if (acc == -1) print()` 不够，要用 `volatile int64_t sink = acc;` 把结果强制落到内存，
再测才是可信的 2.2 ms。

工程组织建议（本工程的做法）：源码 `addons/<name>/src/`、`SConstruct` 里用环境变量
`GODOT_CPP_DIR` 定位 godot-cpp、`build.sh` 一键克隆+编译、**二进制不提交**（架构相关），
测试里检测到类不存在就跳过而不是判失败。

## 22. Navigation 3D 寻路（运行时构建导航网格）

```gdscript
var nm := NavigationMesh.new()
nm.cell_size = 0.25
nm.agent_radius = 0.4
nm.vertices = PackedVector3Array([...])          # 顶点池
nm.add_polygon(PackedInt32Array([3, 2, 1, 0]))   # 一个凸多边形（顺时针，XZ 平面）
var region := NavigationRegion3D.new()
region.navigation_mesh = nm
add_child(region)
var map := region.get_navigation_map()
var path := NavigationServer3D.map_get_path(map, from, to, true)
```

- **无需烘培成文件**：手搓 `vertices + add_polygon` 后 NavigationServer 直接接受。
- **坑 1（最坑）**：多边形只有共享**完全一致**的边才会连通，几何上"部分重叠"不算。
  我拼 L 形走廊时竖向段写 `x∈[6,10]`、横向段是 `x∈[2,10]`，结果路径停在 `(6,-4)` 边界不动 ——
  因为共享边只有一半。改成把横走廊拆成 `x[-10,2] / [2,6] / [6,10]` 三段后立刻连通。
- **坑 2**：导航地图是**异步同步**的，别硬等固定帧数（我等 6 帧时 `map_get_path` 返回 0 个点）。
  正确做法是轮询到能查到路径为止：
  ```gdscript
  for i in range(180):
      await get_tree().physics_frame
      if NavigationServer3D.map_get_path(map, from, to, true).size() >= 2:
          break
  ```
- **诊断技巧**：`map_get_closest_point(map, p)` —— 若返回点与 p 重合，说明 p 在网格上；
  我拿它验证"凹口是否被误当可走"（返回 `(-5,0,-4)` 边界点 = 确实不可走）。
- `NavigationAgent3D` 用法：设 `target_position`，每帧取 `get_next_path_position()` 自己算位移，
  `is_navigation_finished()` 判到达。实测 220 帧走到 22.6 单位外的目标，误差 0.73。

实测（L 形地图）：直线 21.9，实际路径 **26.5**，4 个路径点，确实绕行。

## 23. 权威服务器 + 输入同步 + 断线重连

模型：客户端**只发输入**，位置由服务器计算，再用 `MultiplayerSynchronizer` 复制回客户端。

```gdscript
# 客户端每帧
pawn.post_input.rpc_id(1, 1.0)
# 服务器
@rpc("any_peer", "call_remote", "unreliable_ordered")
func post_input(dir: float) -> void:
	if not multiplayer.is_server(): return
	input_dir = clampf(dir, -1.0, 1.0)
# 服务器 _physics_process 里积分，客户端不动位置
```

- **坑 1**：`MultiplayerSynchronizer` 必须**两端都创建**且配置一致。
  我只在服务器创建 → 客户端报 `Node not found: "MpRoot/World/Pawn/Sync"` 且状态完全不复制。
- **坑 2**：别用墙钟猜时序。服务器"等 3 秒就汇报、5.5 秒退出"，客户端晚 2 秒启动 →
  输入发到一半连接已被掐断（`Trying to call an RPC via a multiplayer peer which is not connected`）。
  改成显式轮询 `multiplayer.get_peers().size()` / `get_connection_status()`。
- **坑 3**：上一轮残留的服务端进程会占端口，新服务端直接报 `Couldn't create an ENet host`。
  跑双进程测试前先 `pkill -f "godot --headless"`。
- 实测结果：
  - 权威同步：服务端 x=6.000（clamp 到上限），客户端复制 x=6.000，**差 0.0000**（客户端从未改过自己的位置）
  - 断线重连：第二个客户端零输入接入，**连上即看到 x=6.000**（加入时会做完整状态同步）

## 24. Forward+ vs GL 兼容渲染器（实测差异）

```bash
godot --path . res://scenes/render_compare.tscn --rendering-method gl_compatibility
godot --path . res://scenes/render_compare.tscn --rendering-method forward_plus
```

| | gl_compatibility | forward_plus |
|---|---|---|
| 驱动 | `opengl3`（OpenGL 4.1 via Metal） | `metal`（Metal 3.2） |
| SSIL | ❌ 报"only available when using the Forward+ renderer" | ✅ |
| SSR | ❌ 同样被禁用并警告 | ✅ |
| glow / SSAO / tonemap | ✅ 可用 | ✅ |

- **重要**：`--headless` 下两种方法的 `RenderingServer.get_rendering_device()` 都是 null、
  adapter 为空（headless 用 dummy 渲染）→ **渲染器对比必须开窗口**，headless 只能看方法名。
- 同一份场景两种渲染器都能跑，差异集中在被禁用的后处理特性上（截图见 `docs/render_*.png`）。

## 25. Skeleton3D 骨骼

```gdscript
skel.add_bone("root")
skel.add_bone("upper")
skel.set_bone_parent(1, 0)
skel.set_bone_rest(1, Transform3D(Basis(), Vector3(0, 1, 0)))
skel.reset_bone_poses()
skel.set_bone_pose_rotation(0, Quaternion(Vector3.RIGHT, deg_to_rad(90.0)))
skel.get_bone_global_pose(1)     # → origin 变到 (0, 0, 1)
```

- **旋转方向**：绕 `+X` 转 90°（右手系）时 `+Y → +Z`，不是 `-Z`。我第一次断言写反了。
- **用动画驱动骨骼**：值轨道的路径是 `NodePath("Skeleton3D:bones/1/rotation")`，
  关键帧值是 `Quaternion`，配合 `Animation.UPDATE_CONTINUOUS`。
  实测 `seek(0.5)` 后 `get_bone_pose_rotation(1)` 的角度 > 0.2 rad，说明确实在被动画驱动。
- 本工程没有做蒙皮（Skin + 带骨骼权重的网格），只验证了骨骼层级与姿态：

## 26. GPUParticles3D

- **坑 1**：`ParticleProcessMaterial.color_ramp` 的类型是 **Texture2D**，
  直接赋 `Gradient` 会编译失败 → 要用 `GradientTexture1D` 包一层。
- **坑 2**：场景里**没有 Camera3D 就什么都不渲染**，`RENDER_TOTAL_PRIMITIVES_IN_FRAME` 恒为 0，
  看起来像"粒子没生效"。加相机后：发射前 0 → 发射后 **600**（300 粒子 × 2 三角形）。
- billboard 粒子：`StandardMaterial3D.billboard_mode = BILLBOARD_PARTICLES` +
  `shading_mode = UNSHADED` + `vertex_color_use_as_albedo = true`，用 `QuadMesh` 当 `draw_pass_1`。
- headless 下只能验证配置（amount/lifetime/材质），看不到粒子；视觉验证必须开窗口（`docs/particles.png`）。

## 27. 低同步率下的客户端插值（多人手感）

服务器把 `MultiplayerSynchronizer.replication_interval` 设成 `0.2`（5 Hz），客户端两种画法对比：

```
同步包数量 = 31（7 秒内，5Hz 理论 ≈35 个）
raw 单帧最大跳变   = 0.267 单位
插值后单帧最大跳变 = 0.109 单位
```

- 结论：**直接把同步来的位置赋给可视节点会一顿一顿**（1 个间隔攒一次位移）；
  用"延迟一个同步间隔 + 两点前向插值"能显著平滑。
- **坑 1**：插值方向别写反 —— `lerp(新快照, 旧快照, alpha)` 是"倒退"，会让物体在收到新包时
  往回跳（我第一版测得 1.933 单位跳变）。应该是 `lerp(旧, 新, alpha)`，且用 `t - 间隔` 作为渲染时刻。
- **坑 2**：两点插值扛不住**方向突变**（我最初让 pawn 在 ±6 之间折返，实测跳变仍有 0.286，
  因为边界反向对插值是断点）。要么在协议里带速度/方向，要么用带缓冲的时间轴（固定延迟 2 个间隔）。
- **坑 3**：**统计口径**要小心 —— 我用"环形缓冲的 size"当包数，最大值被封顶，误判成只收到 8 个包。
  需要单独计数器。

## 28. 3D 物理进阶（4 个 API 的语义差别）

| API | 用途 | 实测结论 |
|---|---|---|
| `RayCast3D` + `add_exception()` | 单条射线 | 从 y=6 向下先命中 Ghost；`add_exception(Ghost)` 后射线穿过它命中 Floor |
| `ShapeCast3D` | 形状扫掠 | **碰到第一个物体就停**，只报最近命中（我的球扫跨两块平台，结果数=1） |
| `PhysicsDirectSpaceState3D.intersect_shape()` | 静态多点重叠查询 | 一次返回 2 个重叠：`Floor, Ghost` ← 要"一次拿全部"用这个 |
| `move_and_collide()` | 单步移动并返回碰撞 | 返回 `KinematicCollision3D`：法线 `(0,1,0)`、碰撞体 Floor、行进 0.40 |

- `Area3D` 的 `collision_mask` 是**过滤谁进来**：mask=1 时 layer1 的 Faller 触发 `body_entered`，
  layer2 的 Visitor 完全不触发。
- 想"沿途能撞到多个物体"，别指望 ShapeCast3D —— 用 `intersect_shape()` 或自定义分段扫描。

## 29. 音频：总线、效果链、2D 定位音

```gdscript
var idx := AudioServer.bus_count
AudioServer.add_bus(idx)
AudioServer.set_bus_name(idx, "SFX")
AudioServer.set_bus_send(idx, "Master")
AudioServer.set_bus_volume_db(idx, -6.0)
AudioServer.add_bus_effect(idx, reverb)      # AudioEffectReverb(room_size=0.7, wet=0.3)
AudioServer.add_bus_effect(idx, AudioEffectLimiter.new())
```

- 可用 API 验证：`get_bus_index("SFX")`、`get_bus_volume_db`、`get_bus_effect_count`、
  `is_bus_mute` / `is_bus_solo`、`get_bus_send`，以及 `AudioStreamPlayer2D` 的
  `bus / max_distance / attenuation / panning_strength` —— 13 项断言全部通过。
- **headless 下音频驱动是 `Dummy`**，只能验证配置与 `playing` 状态。
- **已破案（前一轮记为"未解决"的那个）**：`get_bus_peak_volume_left_db()` 恒为 -200 的真正原因是
  **场景里没有 `Camera2D` 监听者** —— `AudioStreamPlayer2D` 在没有监听者时**根本不发声**（不是衰减问题，
  是静音），于是总线峰值表自然是 -200。
  - 有相机：SFX 总线峰值 **-9.1 dB**（20 帧里 19 帧有效）
  - 无相机：恒 -200
  - 排查中走过的弯路：把声源从 100→10 单位、去掉 Limiter、换长音源都无效（因为这些都不是原因）；
    一度以为"无相机也能响"是因为我用 `remove_child(cam)` 做对照，而**视口里残留了旧的监听者引用**，
    真正干净的对照必须"从头就没加过相机"。
- 顺带确认的事实：
  - **非 Master 总线**的峰值表是可以读的（自定义总线自己 -4.4 dB 也能读到）
  - 效果会改变电平：Reverb 让 -5.2 → -4.2 dB；再加 Limiter 后 **Master 峰值被抬到 +1.1 dB**，而总线自身仍是 -4.4
  - `AudioStreamPlayer2D` 的 `max_distance`/`attenuation` 按预期衰减：同样响度在 10 单位外掉约 6 dB

## 30. 蒙皮动画（手搓骨骼权重）

```gdscript
arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([...])
arrays[Mesh.ARRAY_BONES] = PackedInt32Array([...])     # 每个顶点 4 个骨骼索引
arrays[Mesh.ARRAY_WEIGHTS] = PackedFloat32Array([...]) # 每个顶点 4 个权重（和为 1）
arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([...])
var mesh := ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

var skin := Skin.new()
skin.add_bind(0, skel.get_bone_global_rest(0).affine_inverse())
skin.set_bind_name(0, "root")     # 用名字映射，避免索引对不上
var mi := MeshInstance3D.new()
mi.mesh = mesh; mi.skin = skin
mi.skeleton = NodePath("../Skeleton3D")   # 相对 MeshInstance3D 的路径
```

- 断言：`surface_get_format(0)` 里含 `ARRAY_FORMAT_BONES|ARRAY_FORMAT_WEIGHTS`、
  `skin.get_bind_count()==2` 且 `get_bind_name()` 是 `root`/`upper`、
  `mi.get_node_or_null(mi.skeleton)==skel`、窗口模式下图元数 >0（确实在渲染）。
- **坑（排查了 20 分钟）**：手搓 `ARRAY_INDEX` 时**三角形绕序写反**，网格被背面剔除 →
  视口里空无一物，但图元数是正常的（引擎确实提交了绘制）。
  先用 `material_override.cull_mode = CULL_DISABLED` 判断是不是绕序问题，再回去修索引。
- 视觉验证：`docs/skin_pose0.png`（直立）vs `docs/skin_pose1.png`（upper 绕 Z 弯 70°，网格跟着弯成 L 形）。


## 31. 丢包/延迟下的上行设计（确定性仿真）

`tests/net_sim.gd` 用纯 GDScript 仿真一条上行通道：**30% 丢包 + 60ms 延迟 ±20ms 抖动**，
对比三种策略（60 tick/s，4 秒，速度 1 单位/秒）：

| 策略 | 平均误差 | 最大误差 | 首次移动滞后 |
|---|---|---|---|
| A 每帧只发当前输入（不可靠） | **0.650** | 1.333 | 50 ms |
| B 冗余：每包带最近 5 个输入 + 服务器按 seq 去重 | **0.063** | 0.133 | 50 ms |
| C 冗余 + 客户端预测（本地立刻移动） | **0.000** | 0.000 | 50 ms |

结论与工程含义：

1. **只发当前输入 + 不可靠传输会在丢包下"丢位移"** —— 服务器少了 30% 的移动指令，
   位置永久落后（4 秒后 2.67 vs 真值 4.00）。这就是为什么联网游戏**从不**这么发输入。
2. **输入冗余（每包重复最近 N 个输入 + 服务器按序号去重）** 把误差从 0.650 压到 0.063（约 10 倍）。
   代价是带宽（N 倍），所以真实项目里 N 通常取 3~5，并配合 ack/窗口。
3. **客户端预测**让"本地看到的自己"零延迟零误差，但它**掩盖**了服务器的落后 ——
   真正的做法是预测 + 周期性对账（reconciliation）：服务器回传权威状态和已处理的输入序号，
   客户端回滚到该状态并重放未确认输入。C 里我只做了前半段，所以 server_x 仍落后（3.90 vs 4.00）。
4. 60ms 单向延迟 → 首次移动滞后 50ms（仿真里取整到 tick），量级合理。

## 32. 回滚重放（rollback netcode）

`tests/rollback_sim.gd`：延迟 6±3 tick、远端输入每 30 tick 反向一次，对比两种做法。

| 方案 | 排空后与权威的误差 | 备注 |
|---|---|---|
| 回滚重放 | **0.000000** | 400 次回滚，平均修正 3.04，最大 18 |
| 朴素（当时算完不再改） | **11.0** | 每次方向变化都留下永久偏差 |
| 回滚 + 10% 丢包 | **36.0** | 丢掉的输入永远没到 → **回滚救不了，必须冗余/ack** |

关键结论：

1. **回滚 = 保存"输入 + 状态"，收到迟到输入时回到该 tick 重放**。只要输入最终都到达，
   排空后状态可以**精确**等于权威（误差 0.000000）。
2. **单次修正量有解析上限 ≈ (延迟 + 抖动) × 输入变化幅度**：本例 (6+3)×2 = **18**，实测正好 18。
   这决定了回滚要保存多少历史状态、以及画面会"抽"多大幅度。
3. **回滚不能修丢包**：丢的输入从来没到，任何重放都无从复原 —— 必须靠冗余（见第 31 节）+ ack。
4. 我踩的坑（都是实现细节，但会让整个结论反过来）：
   - 收到确认输入后**必须写回"估计表"**，否则重放用的还是旧估计 → 修正量恒为 0。
   - 用"当时的快照"当重放基态会被污染（快照本身就是用估计值算的）→ 改为**从 tick 0 全量重放**
     （900 tick 的规模完全无所谓）。
   - 远端输入别设成常数模式：常数的话"用旧值估计"永远猜对，测不出任何东西。

## 33. UI Theme 体系

```gdscript
var th := Theme.new()
th.default_font_size = 20
th.set_stylebox("normal", "Button", style)
th.set_stylebox("normal", "DangerButton", red_style)
th.set_type_variation("DangerButton", "Button")     # 变体继承 Button 的一切
control.theme = th                                  # 挂在根上，子控件自动继承
btn.theme_type_variation = "DangerButton"           # 这个按钮用变体外观
```

- 优先级（实测）：**节点 override > 类型变体 > 主题(该类型) > ThemeDB 默认**
- 断言覆盖：主题取值、子控件继承（颜色/字号/StyleBox）、变体样式不同于基础类型、
  节点 override 压过主题、以及 `.tres` 存取往返（`ResourceSaver.save` → `load` 后样式与变体都在）。
- **坑**：Godot 4.7 的 `Theme` **没有 `has_type_variation()`**（调用会报
  `Nonexistent function`），要查变体关系用 `get_type_variation_base("DangerButton") == "Button"`。
- 视觉：`docs/ui_theme.png`（绿=主题 Button、红=类型变体、蓝紫=单节点 override）。
- 另一个反复踩的坑：**用脚本（或 python）往 GDScript 里注入中文时，别在双引号字符串里再写双引号** ——
  会截断字符串导致解析失败，而**解析失败后进程会挂住**，看起来像死循环（这次又中招一次）。
