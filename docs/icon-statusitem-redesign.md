# 图标与菜单栏动效改造清单

> 项目：拾光 Gleam（目录仍为 mac-selected-translator）  
> 日期：2026-09-18  
> 涉及文件：`scripts/generate_app_icon.swift`、`Sources/GleamApp/StatusItemIconView.swift`

---

## 一、App 图标：定稿方案 C（棱镜内雕 A/文）

### 1.1 设计说明

| 项    | 内容                                        |
| ---- | ----------------------------------------- |
| 概念   | 棱镜折射：一道白光射入玻璃棱镜，散成四道彩带                    |
| 隐喻   | 一段输入 → 多种产出（翻译 / 润色 / 流程图 / 其他模块），不逐项列举功能 |
| 风格   | Liquid Glass：磨砂半透玻璃、柔和折射、细亮边缘高光、环境色渗透     |
| 品牌锚点 | 棱镜玻璃内部蚀刻「A」与「文」，与菜单栏现有双卡保持血缘              |
| 尺寸   | 1024×1024，macOS 连续圆角（squircle）安全区构图       |

### 1.2 色彩规范

沿用现有品牌蓝青，另加三个模块色（均为 macOS 系统色）。

| 模块        | 色值                    | 用途         |
| --------- | --------------------- | ---------- |
| 翻译        | `#087CF0` → `#00A6A6` | 主色，光束第一、二道 |
| 电源        | `#FFB020`             | 光束第三道      |
| 工作场景      | `#34C759`             | 光束第四道      |
| iPhone 定位 | `#FF375F`             | 高光 / 补充色   |

### 1.3 待处理事项（替换现有图标前必须完成）

1. **圆角外透明** —— 生成图为白底带边距，四角是白色。需裁成 1024×1024 全出血，圆角外区域置为透明。
2. **出全套 iconset** —— 16 / 32 / 64 / 128 / 256 / 512 / 1024（含 @2x），合成 `AppIcon.icns`。
3. **接入生成脚本** —— 改 `scripts/generate_app_icon.swift`。现有实现是绘制两套圆角卡片（`drawTile`，蓝 `#087CF0` 的 A + 青 `#00A6A6` 的 文），需整体替换为棱镜方案的绘制逻辑；designSize 1024、圆角 205、描边 `#D5E3E7` 这套参数可保留复用。

---

## 二、菜单栏动效：从「转圈」改为「色散」

### 2.1 核心改动

现有翻译中状态是一道**单色蓝弧**绕圈（`translatingOrbitDuration = 0.9`，半径 9.2，线宽 1.2，90° 弧）。  
改为把棱镜的物理过程压缩成一次完整播放：**合拢 → 色散 → 绕转 → 收拢**。

| 阶段  | 时长     | 缓动                | 画面                        |
| --- | ------ | ----------------- | ------------------------- |
| 触发  | 0.18s  | ease-in（加速收拢）     | A/文 双卡向中间合拢，压成一条白色光束      |
| 色散  | 0.35s  | ease-out（快速散开后减速） | 光束向右炸开成四道彩带               |
| 进行中 | 0.9s/圈 | 匀速                | 彩带收拢为一道弧，绕中心旋转            |
| 完成  | 0.25s  | ease-out          | 弧收成一点，A/文 弹回并过冲到 1.06x，回落 |

现有\\<span style="background-color:rgb(255, 238, 173)">\\-</span>

-只有一个 `eased()`（smoothstep），**需要新增 ease-in 与 ease-out 两条曲线**，合拢与色散不能共用同一条。

### 2.2 状态机

| 状态           | 主体         | 弧色           | 说明                               |
| ------------ | ---------- | ------------ | -------------------------------- |
| idle         | A/文 双卡静止叠放 | —            | 定时器停掉，不重绘                        |
| 翻译中          | A/文        | 蓝 → 青        | 主状态                              |
| 润色中          | A/文        | 青 → 蓝（反向）    | 暗示对同一段文字做反向处理                    |
| 流程图生成中       | A/文        | 青 → 琥珀       |                                  |
| 场景恢复中        | 绿色窗格       | 绿 `#34C759`  | 叠加 1.4s 边缘循环光带，与面板光带同语言          |
| iPhone 定位中   | 玫红定位针      | 玫红 `#FF375F` |                                  |
| 通用忙碌 / 多任务并行 | A/文        | 四色渐变弧        | 唯一使用完整色散的场景                      |
| 电源态          | 琥珀闪电，静态    | —            | 保持现状，仅数值或主题变化时重绘                 |
| 失败           | tile 转红    | —            | 横向抖 2 次（±1.5pt / 0.08s），0.4s 后回落 |

**配色规则**：有明确模块时用该模块的单色弧；只有「通用忙碌 / 多任务并行 / 未知模块」才用四色渐变弧。若所有状态都上四色，会淹没「现在哪个模块在跑」这个信息。

### 2.3 idle 行为

- **去掉常驻动画**。现在是 30fps 常驻定时器，空闲也每 33ms 重绘一次位图、持续唤醒主线程——对一个电源监控类 App 不合适。
- 改为**事件驱动**：收到任务启动 timer，动画结束即 `invalidate()`。
- 可保留的「活着」暗示：每 6s 一次 0.8s 的 A/文 互换（可选，可关）。现有 idle 的 5.76s 三重动作（位移 + 2π 翻转 + 2π 旋转）在小尺寸偏忙，建议简化为位移 + 一次翻转，呼吸幅度从 ±4% 降到 ±2%。

---

## 三、代码改动清单

全部集中在 `Sources/GleamApp/StatusItemIconView.swift`。

### 3.1 `StatusItemVisualStyle` 新增常量

```swift
static let dispersionCollapseDuration: TimeInterval = 0.18
static let dispersionBurstDuration: TimeInterval = 0.35
static let arcCycleDuration: TimeInterval = 0.9
static let settleDuration: TimeInterval = 0.25
static let failureShakeDuration: TimeInterval = 0.08
static let failureShakeOffset: CGFloat = 1.5
```

现有 `translatingSwapDuration`（1.1）、`translatingOrbitDuration`（0.9）、`idleBreathingDuration`（2.3）、`idleMotionDuration`（5.76）按 2.3 节调整或废弃。

### 3.2 状态枚举扩展

`StatusTranslationIconState` 目前只有 `idle` / `translating` 两个 case，需扩展为：

```swift
case idle, translating, polishing, flowcharting, restoringWorkspace, locating, busy, failed
```

每个 case 携带对应的弧色（或返回一组色停点）。

### 3.3 绘制改动

| 位置                                     | 现状                              | 改为                      |
| -------------------------------------- | ------------------------------- | ----------------------- |
| `image(at:isDark:reduceMotion:)` 中的轨道弧 | 单段 90° 弧，纯 `blue`，半径 9.2，线宽 1.2 | 分段绘制的渐变弧                |
| `drawTile`                             | 固定蓝 / 青两色                       | 填充色随活跃模块变化（四色皮肤）        |
| `eased(_:)`                            | 仅 smoothstep                    | 新增 `easeIn` / `easeOut` |
| 合拢与色散帧                                 | 无                               | 新增绘制分支                  |

**渐变弧实现建议**：不要用 `CGGradient` 直接描边（`CGContext` 对路径描边不支持直接渐变）。改用 **`CGContext` 分段画 4 段圆弧**，每段单独 `setStrokeColor`，段间留约 15° 缺口——视觉上更像「被拆开的光」，也比 `replacePathWithStrokedPath` + clip + 填充渐变简单可控。

### 3.4 定时器改为事件驱动

`updateTimer()` 现在在 `start()` 中无条件启动 1/30 定时器并加入 `.common` run loop。改为：

- `animationState` 切到非 idle 时启动，切回 idle 或动画结束时 `invalidate()`
- `accessibilityDisplayShouldReduceMotion` 时保持现状（不启动）

### 3.5 深浅色适配

`image(at:isDark:reduceMotion:)` 里已有 blue / teal 两套色值。新增琥珀、绿、玫红**各补一套 dark 值**。参考现有 dark 色偏亮、饱和度略降的做法（如 blue light `0.031,0.486,0.941` → dark `0.365,0.667,1`）。

### 3.6 reduce motion 降级

保留颜色区分：弧停在 12 点方向不转，该什么色还什么色，**不要退化成灰色**。合拢 / 色散 / 抖动全部跳过，直接呈现进行中的静态帧。

---

## 四、待决问题

1. **绿色撞色** —— 工作场景绿 `#34C759` 与禁止休眠绿点（light `0.145,0.663,0.31`）撞色。两个同时出现时分不清，且现在色相承担了「哪个模块在跑」的识别功能，冲突比之前更碍事。**建议**把休眠点改为中性白 / 浅灰，定位为系统级徽标而非功能模块。
2. **idle 互换是否保留** —— 6s 一次的 0.8s 互换，建议保留但做成可关。

---

## 五、实施记录

### 5.1 图标资产（已完成）

- 主图 `assets/AppIconMaster.png`：1024×1024 RGBA，用超椭圆（n=5）蒙版把圆角外置为透明，边缘做 4×4 边界超采样抗锯齿。原始稿存 `assets/AppIconSource.jpg`。
- `scripts/generate_app_icon.swift` 改为从主图高质量缩放出全套 iconset，不再程序化绘制卡片。已验证：10 个尺寸全部生成、`iconutil` 合成 `AppIcon.icns` 成功、各尺寸四角 alpha 均为 0。
- 主图缺失时脚本会明确报错并退出（exit 66），不会静默产出旧图标。

### 5.2 菜单栏动效（已完成，对应第三节 3.1–3.6）

- 新增常量、状态枚举扩展、分段渐变弧、模块色皮肤、easeIn / easeOut、事件驱动定时器、四色深色值、reduce motion 降级均已落地。
- **空闲改为默认静止**：新增 `StatusItemIconAnimator.idleExchangeEnabled`（默认 `false`）。关闭时空闲不启动定时器、不逐帧重绘；置 `true` 可恢复原来的 A/文 互换（呼吸幅度降到 ±2%）。
- 休眠绿灯按第四节建议改为中性灰白（`StatusItemPalette.neutral`），与「工作场景」绿区分。想回退只需把 `drawSleepIndicator` 里的 `tint` 换回固定绿色。
- 休眠脉冲仍在跑，因此 `isPreventingSleep` 为 true 时定时器不会停——这是刻意的，脉冲本身就是「我正阻止休眠」的信号。
- 测试 `statusIconUsesNativeImageWithoutClickOverlays` 原断言「空闲两帧必然不同」，与新的空闲静止语义冲突，已改为：默认断言两帧一致，开启互换后再断言有动画。

### 5.3 未接线（需确认后再做）

状态机已完整实现，但 `AppDelegate` 目前只在翻译时切 `.translating` / `.idle`。其余模块需要在各自任务开始与结束时设置一次状态，各一行：

```swift
statusIconAnimator?.animationState = .polishing          // 润色开始
statusIconAnimator?.animationState = .flowcharting       // 流程图生成开始
statusIconAnimator?.animationState = .restoringWorkspace // 场景恢复开始
statusIconAnimator?.animationState = .locating           // iPhone 定位开始
statusIconAnimator?.animationState = .busy               // 通用忙碌 / 多任务并行
statusIconAnimator?.animationState = .failed             // 请求失败（0.72s 后自动回落 idle）
statusIconAnimator?.animationState = .idle               // 结束
```

未接线的原因是这几个模块的任务生命周期分散在不同 Controller 里，贸然接入容易漏掉异常分支导致图标卡在某个状态。确认要接时，建议从润色（`ContentPolishWindowController`）和场景恢复（`WorkspaceRestoreRunner`）两个入手。

---

## 六、验收清单

图标：

- [x] 圆角外区域透明，1024×1024 全出血
- [x] iconset 全套尺寸齐全，`AppIcon.icns` 生成成功
- [ ] 16pt 下仍能认出「一道光被分成几束」——**需人工过目**
- [ ] 方案 C 的 A/文 内雕清晰可辨——**需人工过目**

菜单栏：

- [ ] idle 状态下无定时器在跑——代码已实现，**需用 Instruments 实测主线程无周期性唤醒**
- [ ] 每个模块状态的弧色正确——已实现，但除翻译外尚未接线
- [x] 合拢 / 色散缓动方向正确（ease-in / ease-out 不反）
- [x] 开启「减少动态效果」后：弧停 12 点方向，颜色区分保留
- [x] 深色模式下蓝 / 青 / 琥珀 / 绿 / 玫红均定义了深色值
- [x] 失败态抖动后能正确回落（0.32s 抖动 + 0.4s 停留后自动回 idle）

> 注：图标是 AI 生成的位图，我无法在本机直接查看渲染结果，上面两条「需人工过目」请你跑一遍 `./scripts/build_app.sh` 后在 Dock 里确认。若 16pt 下彩带糊成一团，最省事的办法是把主图里棱镜和彩带整体放大一圈再重新生成。
