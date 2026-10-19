# VolumeGlass 音量玻璃

把系统**音量 HUD**（贴左边缘那个竖条）做成 iOS 26 那种液态玻璃胶囊，并从侧面滑入。
独立插件，不依赖、不改动任何第三方插件。

针对的目标就是截图里那个东西：竖着的长条、上半截半透明、下半截白色填充。
它本身没有圆角问题，问题是**材质太平**、没有玻璃边、出现得太生硬。

```
VolumeGlass/
├── Makefile                       # theos 工程（tweak + 设置面板 bundle）
├── control                        # deb 元信息
├── VolumeGlass.plist              # 注入范围：com.apple.springboard
├── Tweak.xm                       # hook 安装 + 音量/亮度判定 + 宿主层定位
├── VGConfig.h/.m                  # 读 com.shiyi.volumeglass 偏好域
├── VGDecor.h/.m                   # 胶囊圆角 + 玻璃底色 + 锥形渐变描边 + 侧面滑入
├── VGRootListController.h/.m      # 设置面板控制器
├── layout/                        # 静态文件（PreferenceLoader 入口 + 面板 specifier）
└── .github/workflows/build.yml    # 云端编译，产出 deb
```

## 1. 编译

本机 Windows 的 lld 出不了可用 deb，走 GitHub Actions：

```bash
git init && git add . && git commit -m init
git remote add origin git@github.com:<你的账号>/VolumeGlass.git
git push -u origin main
```

推送后 Actions 自动跑，产物在 Artifacts → `VolumeGlass-deb`。
有 macOS 也可以本地编：`export THEOS=~/theos && make package FINALPACKAGE=1`。

## 2. 安装

deb 传到手机，Filza / Sileo / `dpkg -i` 都行。装完自动 respawn SpringBoard。

- rootless（8P）和 roothide（14PM）都能装：工程里没有绝对路径，偏好走 `CFPreferences`，
  装载位置交给 theos 的 `rootless` scheme。
- 依赖 `mobilesubstrate`，RootHide 上由 ElleKit 提供兼容层。

## 3. 用法（先点预设，再微调）

设置 → 音量玻璃 → **「套用 iOS 26 预设」**，然后按一下音量键。

预设 = 自动胶囊 + 薄玻璃（底色 0.06）+ 额外模糊 + 玻璃描边 + 侧面滑入。

| 项 | 默认 | 说明 |
|---|---|---|
| 启用 | 开 | 总开关 |
| 自动胶囊 | 开 | 圆角取短边一半，竖条就是标准胶囊 |
| 圆角 | 26 | 关掉自动胶囊后才生效，0~60 |
| 玻璃底色 | 0.12 | 白色叠加，越大越"磨砂白" |
| 玻璃描边 | 开 | 锥形渐变环，模仿液态玻璃的折射边 |
| 额外模糊 | 关 | 再叠一层 `systemUltraThinMaterial`（预设会打开） |
| 侧面滑入动画 | 开 | 从左侧 0.34s 弹入 + 淡入，纯 CAAnimation，不改 model 值 |
| 亮度 HUD 也应用 | 关 | 亮度和音量共用一套 HUD 视图 |
| 向上层数 | 0 | **套错层时调这个** |
| 指定类名 | 空 | 直接点名要着色的视图类 |
| 输出日志 | 关 | 打开后 `log stream --predicate 'eventMessage CONTAINS "VolumeGlass"'` 看类名 |

## 4. 排查

**完全没变化**
1. 打开「输出日志」，按音量键，看有没有 `装饰 host=<类名> bounds=...`；
2. 有这行但看不出变化 → 你选中的层不是可见的那个，把「指定类名」填父/子层类名；
3. 没有这行 → HUD 类名和你系统版本不一致，把日志里的类名发我。

**圆角套错了 / 整个屏幕糊了一层**
不会发生：`VGSizeLooksLikeHUD()` 拦掉宽或高 > 420 的视图，还会拦掉和窗口等大的容器。

**系统阴影没了**
`masksToBounds` 会裁掉原视图的阴影。要阴影就把「玻璃描边」当阴影用，或者把圆角关小。

**白苹果 / 循环重启**
进安全模式（RootHide 音量下键启动），Sileo 里卸载 `com.shiyi.volumeglass`。

## 5. 实现要点

- **注入点**：`SBElasticHUDViewController`（`viewWillAppear:` / `viewDidLayoutSubviews`），
  外加 `SBElasticSliderView`、`SBElasticVolumeSliderView`、`_CCUIBaseSliderContentView`
  的 `layoutSubviews` 兜底 —— iOS 版本之间 HUD 层级会变，多挂几个不吃亏。
- **音量/亮度区分**：扫 HUD 视图树 + 子控制器类名里有没有 `Volume` / `Brightness`，
  判不出来按音量处理。
- **胶囊圆角**：容器 `cornerRadius + cornerCurveContinuous + masksToBounds`，
  材质/模糊子视图（类名含 `Material`/`VisualEffect`/`Backdrop`，或子层里有 `CABackdropLayer`）同步圆角，
  否则四角会露出直角。原值存关联对象，关开关能还原。
- **玻璃**：底色（白 + alpha）+ 顶部 55% 高光 + 锥形渐变描边（`kCAGradientLayerConic` + even-odd 环形遮罩）。
  纯 CoreAnimation，不碰 `CABackdropLayer.filters` ——
  **Liquidify 的 `LYGlassFilterGuard` 清洗过滤器时不会误伤**。
- **侧面滑入**：`CABasicAnimation` 只做 presentation 层动画（`transform.translation.x` + `opacity`），
  动画结束自动回落到真实位置，不会把 HUD 卡在错误坐标。
- **安全阀**：尺寸判断 + 父子层去重（防止两条 hook 各套一圈描边）。

## 6. 已知限制

- **下半截的白色填充不动**。那是音量条的填充层，代表当前音量；改成半透明就看不见音量大小了。
  现在的做法是把它一起裁成胶囊、只加描边和高光。
- 锚点来自 iOS 16.x 的系统类名（与 Liquidify 常量池里的类名互相印证），**没在 16.5 实机跑过**。
  第一次装完如果没效果，开日志把类名发我，改一行就能适配。
- 只处理 HUD 本体，不管转场动画的中间态。
