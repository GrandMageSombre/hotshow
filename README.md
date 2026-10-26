# 热剧速览 (HotShow)

实时热播 **电视剧 / 短剧 / 动漫** 聚合搜索应用，一套 Flutter 代码同时支持 **Windows** 和 **Android**。
发现好剧 → 一键检索完整片源 → 内置播放器直接看，支持选集、倍速与离线缓存。

![平台](https://img.shields.io/badge/平台-Windows%20%7C%20Android-blue) ![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)

## 功能

| 功能 | 说明 |
|------|------|
| 📺 热播榜单 | 电视剧（热门/国产剧/美剧/日剧/韩剧/综艺/纪录片）、短剧（热门短剧/网络剧）、动漫（热门动漫/日本动画/国漫） |
| 🔄 实时更新 | 进入应用自动拉取最新榜单；每 10 分钟自动刷新当前页面；支持下拉刷新与手动刷新按钮；列表无限加载更多 |
| 🔍 自主搜索 | 关键词实时搜索（输入 600ms 自动联想搜索），覆盖电视剧/短剧/动漫/电影，显示评分、年份、地区、演员 |
| 🕘 历史记录 | 搜索历史（可单条删除/一键清空，点击直接重搜）+ 浏览历史（最近看过 100 条，点击回看详情），本地持久化存储 |
| ℹ️ 详情页 | 海报、评分、类型/地区/首播/集数、导演/主演、剧情简介、豆瓣热门短评，一键跳转豆瓣网页 |
| ▶️ 在线播放 | 详情页一键到已配置的采集站检索「完整资源」（多线路 / 全集），内置 media_kit（libmpv）播放器：选集、切线路、倍速、全屏、自动连播 |
| ⬇️ 离线缓存 | 单集或整条线路的 m3u8 分片抓到本地并重写为本地播放列表，断网可看；播放进度本地记忆，下次进入自动续播 |
| 🗄️ 采集站管理 | 站点可增删改、启停、连通性自检；**工程不写死任何影视站点地址**，站点由自动搜索或手动填写得到 |
| 🔎 自动搜索采集站 | **不用填任何地址**，点一下就自动拉取内置的公开清单源并解析出候选采集接口（也支持纯文本 / JSON 数组 / `{"sites":[…]}` / TVBox 风格配置，或手动粘贴），并发探测后标出可用/不可用/已添加，勾选即批量导入 |
| 💬 在线字幕 | 播放页一键搜索 OpenSubtitles（免登录可搜，匿名有频率限制，可填免费 API Key），下载 zip 自动解包、GBK 自动转 UTF-8；支持粘贴字幕直链、管理本剧字幕、时间轴 ±0.5s 实时微调，换集自动重挂 |


## 技术实现

- **框架**: Flutter (Material 3)，单代码库 → Android APK + Windows EXE
- **元数据源**: 豆瓣公开数据（未官方授权，仅供学习）
  - 榜单：`m.douban.com/rexxar/api/v2/subject_collection/*`（网页端集合接口）
  - 短剧/网剧/动漫标签聚合：`frodo.douban.com/api/v2/tv/recommend`（App 端接口，HMAC-SHA1 请求签名）
  - 搜索：`frodo.douban.com/api/v2/search/subjects`
  - 详情：`frodo.douban.com/api/v2/tv/{id}` / `movie/{id}`
- **播放源**: 第三方影视采集站（maccms / 苹果CMS 的 `api.php/provide/vod` 接口），按片名检索后解析 `vod_play_from` + `vod_play_url` 得到多线路、全部分集的播放地址；站点通过「自动搜索」从公开清单源发现，代码里不写死任何站点地址
- **播放器**: [`media_kit`](https://github.com/media-kit/media-kit)（libmpv），Windows 与 Android 双端原生播放 HLS/m3u8，播放/进度/全屏由 `media_kit_video` 的 AdaptiveVideoControls 承担，选集、倍速、缓存按钮为自绘
- **离线缓存**: 自研 m3u8 解析（master 码流选择、`EXT-X-KEY` 逐分片密钥、`EXT-X-MAP`）+ 4 并发分片下载 + 本地播放列表重写，落盘后断网可播
- **在线字幕**: OpenSubtitles（`api.opensubtitles.com/api/v1`）+ 免 Key 的旧站下载通道 `dl.opensubtitles.org/en/download/sub/{legacy_id}`；自研 zip/gzip 解包（中央目录 + stored/deflate）、编码识别（UTF-8 / UTF-16 BOM / GBK）、字幕统一转 UTF-8 落盘；时间轴调整走 libmpv 的 `sub-delay` 实时生效，不支持时回退到重写字幕文件
- **网络图片**: 豆瓣图床会按 **User-Agent** 拦截（Flutter 默认的 `Dart/x.y (dart:io)` 直接返回 403/418，只带 Referer 无效），因此所有海报请求统一带浏览器 UA + 站点 Referer，并在 `img1~img9` 多个 CDN 域名间失败重试
- **本地存储**: `shared_preferences`（Android 应用私有目录 / Windows 用户配置目录）+ `path_provider`（离线分片目录、字幕目录）
- **状态管理**: 轻量 ChangeNotifier + StatefulWidget，无重型依赖

## 播放功能怎么用

1. 打开任意剧集详情页 → 底部 **「播放（检索完整资源）」**；
2. 首次使用会提示「还没有配置采集站」，有两条路：
   - **自动搜索**：点「自动搜索采集站」→ 直接点 **「开始自动搜索」**
     （清单地址留空时会自动使用内置源；想换成自己的清单就填上地址，或点「粘贴地址列表」贴一批）。
     应用会并发探测每个候选接口，**可用的自动勾选**、不可用的写明原因，
     你确认后点底部「添加所选 N 个站点」即可；
   - **手动添加**：点「手动添加」，填名称 + maccms 采集接口地址（如
     `https://你的站点/api.php/provide/vod`）。列表动作默认 `detail`，个别站点可试 `list` / `videolist`；
     卡片上的 🔌 按钮可当场自检。
3. 回到资源页即可看到各站点命中的资源（含线路数、总集数、清晰度备注），点卡片进入播放；
4. 播放页支持：选集、切换线路、倍速、自动连播、缓存当前集、缓存整条线路、上次进度续播（从资源列表进入时自动跳到上次位置）；
5. 播放页右上角 **字幕按钮**（💬）→ 在线获取字幕 / 粘贴直链 / 调整时间轴 / 关闭或改用内嵌字幕。详见下节。

## 字幕怎么用

播放页右上角点 **字幕** 图标：

- **在线获取字幕**：默认用当前片名搜索 OpenSubtitles，顶部还有豆瓣别名（常含英文名）的快捷搜索词——
  多数中文字幕是按英文片名发布的。选中一条后自动下载、解包、转码并挂到画面上；
- **本地与直链**：粘贴 `.srt` / `.ass` / `.vtt` / `.zip` / `.gz` 的字幕直链导入；这里也能管理本剧已下载的字幕、填写 OpenSubtitles 的免费 API Key；
- **时间轴**：字幕面板里「提前 0.5s / 延后 0.5s」实时生效（libmpv `sub-delay`），可一键恢复；
- 每部剧的字幕选择会记住，**换集自动重挂**；字幕文件存在
  `<应用支持目录>/subtitles/<站点ID_资源ID>/` 下，换剧互不干扰。

> OpenSubtitles 的匿名通道按 IP 限流（额度不大），被限流时会提示并给出「填入 API Key」入口；
> 免费 Key 在 <https://www.opensubtitles.com/en/consumers> 申请，只保存在本机。
> 内置字幕源只有 OpenSubtitles：国内字幕站的下载多为压缩包且带防盗链，应用不内置抓取，
> 需要时把直链粘到「本地与直链」里导入即可。

### 自动搜索支持哪些清单格式

**默认（留空清单地址）**：自动使用内置源 `lib/services/source_discovery.dart` 里的 `kDefaultCatalogUrls`
（一个托管在 jsDelivr 上的公开 TVBox 配置），拉取后解析并探测。

想换成自己的来源，把地址填进输入框即可（自己的服务器、Gist、jsDelivr / gitee 上的 JSON 都行），应用会宽容解析：

```text
# 纯文本：每行一个地址，井号是注释
https://a.example.com/api.php/provide/vod/
站点B | https://b.example.com/api.php/provide/vod/
c.example.com          # 只写域名也行，按 maccms 约定补全成 /api.php/provide/vod/
```

```json
["https://a.example.com/api.php/provide/vod/"]
```

```json
{ "sites": [ { "name": "站点A", "api": "https://a.example.com/api.php/provide/vod/" } ] }
```

TVBox 风格的配置也能识别——`api` 是 `csp_XXX` 这类类型名时，会从 `ext` 里的 `site` / `siteUrl` 字段、
或 `ext` 本身就是一个 URL 时还原出真实采集地址；`drpy`/JS 脚本源会被自动跳过，`/at/xml` 后缀会归一化成默认的 JSON 接口。

不打开 App 也可以先验证单个接口是否可用：

```bash
dart run tool/source_check.dart https://你的站点/api.php/provide/vod/ 庆余年
```

> 采集站地址、可用性与内容来源都需要你自己确认；应用只在本地保存这些配置。

## 项目结构

```
lib/
├── main.dart                  # 应用入口 + 底部导航壳
├── models/
│   ├── show_item.dart         # 豆瓣影视条目/详情模型（三种来源 JSON 归一化）
│   ├── media_resource.dart    # 采集站资源模型（线路 / 分集 / maccms 字段解析）
│   ├── subtitle.dart          # 字幕搜索结果 / 本地字幕记录模型
│   └── source_site.dart       # 采集站配置模型（纯 Dart，可 dart run 直用）
├── services/
│   ├── api_client.dart        # HTTP 层：frodo 签名客户端 + rexxar 客户端 + 统一错误
│   ├── remote_ua.dart         # 统一的浏览器 User-Agent（豆瓣图床/字幕站都认它）
│   ├── show_service.dart      # 豆瓣业务层：榜单/搜索/详情（不依赖 Flutter，可单独测试）
│   ├── resource_service.dart  # 采集站检索层：多站并发搜索 + 片名匹配排序
│   ├── source_store.dart      # 采集站配置持久化
│   ├── source_discovery.dart  # 采集站自动发现：清单解析 + 并发探测
│   ├── subtitle_service.dart  # 字幕业务层：搜索/下载/解包/转码/落盘/偏移
│   ├── subtitle_store.dart    # 字幕文件与「每部剧选中哪条」的本地持久化
│   ├── subtitle/
│   │   ├── open_subtitles.dart  # OpenSubtitles 搜索 + 免 Key 下载通道
│   │   ├── zip_reader.dart      # zip/gzip 解包（中央目录 + stored/deflate）
│   │   ├── subtitle_text.dart   # 编码识别（UTF-8/UTF-16/GBK）与时间轴偏移
│   │   └── subtitle_exception.dart # 字幕异常与用户可读文案
│   ├── m3u8.dart              # M3U8/HLS 播放列表解析与本地列表生成（纯 Dart）
│   ├── offline_cache.dart     # 分片下载/离线缓存（并发、取消、断点目录管理）
│   ├── playback_store.dart    # 播放进度（续播）持久化
│   └── history_store.dart     # 搜索历史 + 浏览历史（本地持久化）
├── pages/
│   ├── home_page.dart         # 三个分类 Tab + 子榜单切换 + 实时刷新
│   ├── search_page.dart       # 搜索页（防抖联想 + 搜索历史）
│   ├── history_page.dart      # 历史记录页
│   ├── detail_page.dart       # 详情页
│   ├── resource_page.dart     # 资源检索页（多站点聚合结果）
│   ├── player_page.dart       # 播放页（media_kit + 选集/倍速/缓存/字幕）
│   ├── subtitle_page.dart     # 在线字幕页（搜索 / 直链导入 / 本剧字幕管理）
│   ├── site_settings_page.dart# 采集站管理页
│   └── source_discovery_page.dart # 自动搜索采集站页
└── widgets/
    ├── show_card.dart         # 海报卡片（评分角标）
    ├── show_grid.dart         # 海报网格度量（列数/卡片宽高唯一来源）
    ├── remote_image.dart      # 网络图片（UA/Referer + 多域名重试 + 占位）
    └── common_views.dart      # 错误重试/空态/列表尾组件
tool/api_check.dart            # 豆瓣数据层真实接口集成测试（dart run 直跑）
tool/source_check.dart         # 采集站接口连通性验证（dart run 直跑）
tool/discover_check.dart       # 清单拉取 + 批量探测（dart run 直跑）
tool/subtitle_check.dart       # 字幕搜索/下载/解包验证（dart run 直跑）
test/widget_test.dart          # UI 冒烟测试（注入假数据，不访问网络；含窄屏/大字号回归）
test/resource_test.dart        # 采集站检索/解析/排序单测（本地假接口）
test/discovery_test.dart       # 清单解析 + 并发探测单测（本地假清单/假站点）
test/offline_test.dart         # m3u8 解析与分片缓存单测（本地假 HLS 服务）
test/subtitle_test.dart        # 字幕编码/解包/偏移/存储 + 网格度量单测
```

## 构建与运行

前置条件：[Flutter SDK](https://docs.flutter.cn/get-started/install)（建议 3.35+，本工程在 3.47 上开发验证）。

> ⚠️ **首次构建需要能访问 GitHub Releases**：播放器 `media_kit` 会在构建期下载 libmpv 原生库
> —— Android 为 `media-kit/libmpv-android-video-build` 的若干 `.jar`（arm64-v8a / armeabi-v7a / x86_64 / x86），
> Windows 为 `libmpv-dev-x86_64.7z`。
> 国内网络常常能打开 `github.com`，但**连不上实际承载资源的 `objects.githubusercontent.com`**，表现为
> Gradle 长时间停在 `Downloading file from: https://github.com/...` 不动，或 CMake 卡住。
> 遇到这种情况请先配置代理再构建：
>
> ```powershell
> $env:HTTP_PROXY  = 'http://127.0.0.1:7890'
> $env:HTTPS_PROXY = 'http://127.0.0.1:7890'
> flutter build apk --release
> ```
>
> 仅做数据层与逻辑验证（`flutter analyze` / `flutter test` / `dart run tool/*.dart`）**不需要**这些原生库。

> 💡 **GitHub 完全不可达时的土办法**：`media_kit_libs_android_video` 的 Gradle 脚本会先看
> `build/media_kit_libs_android_video/v1.1.7/` 下有没有 jar，**存在且 MD5 匹配就直接跳过下载**。
> 所以可以用任何可达的加速镜像（如 `https://gh-proxy.com/https://github.com/…`）手动把这 4 个 jar
> 下到该目录，再执行构建。文件名与 MD5 见
> `$PUB_CACHE/hosted/pub.flutter-io.cn/media_kit_libs_android_video-1.3.8/android/build.gradle`。

> ⚠️ **`PUB_CACHE` 必须与工程在同一个盘符**：若工程在 `C:\` 而 `PUB_CACHE=D:\pub-cache`，
> 编译插件 Kotlin 源码时会抛
> `Could not close incremental caches … java.lang.IllegalArgumentException: this and base files have different roots`
> —— Kotlin 增量编译无法为跨盘符的文件计算相对路径，且**关掉 `kotlin.incremental` 也没用**。
> 用目录联接即可复用已有缓存、不额外占空间：
>
> ```powershell
> cmd /c mklink /J C:\pub-cache D:\pub-cache
> $env:PUB_CACHE = 'C:\pub-cache'
> flutter pub get      # 必须重新 pub get，让 .dart_tool 指向新路径
> flutter build apk --release
> ```

### 直接安装（Android）

本项目已构建好发行版 APK：

```
releases/spgj-v1.1.0-android.apk   （92.7MB，含播放器与自动搜索，release 签名可直接安装）
releases/spgj-v1.0.0-android.apk   （49.7MB，旧版：仅榜单/搜索/详情，无播放能力）
```

> v1.2.0（本轮：图片加载修复 + 网格溢出修复 + 在线字幕）只改了源码，**尚未重新打包 APK**；
> 需要时按下面的命令自行构建，产物仍叫 `app-release.apk`。

传到手机上点击安装即可（需允许"安装未知来源应用"），或用 adb：

```bash
adb install releases/spgj-v1.1.0-android.apk
```

> v1.1.0 体积变大是因为内置了 3 个 ABI 的 `libmpv.so`（arm64-v8a / armeabi-v7a / x86_64，每个约 12MB）。
> 只想出精简包可以按 ABI 拆分：`flutter build apk --release --split-per-abi`。

### 本地开发

```bash
flutter pub get

# 本地调试运行（连接的设备/模拟器）
flutter run

# 豆瓣数据层接口连通性验证（不需要任何设备）
dart run tool/api_check.dart

# 采集站接口连通性验证（不需要任何设备）
dart run tool/source_check.dart https://你的站点/api.php/provide/vod/ 庆余年

# 字幕链路验证：搜索 → 免 Key 下载 → 解包 → 编码识别（不需要任何设备）
dart run tool/subtitle_check.dart Inception zh-cn
# 搜索接口被匿名限流时，可只验证下载链路
dart run tool/subtitle_check.dart --legacy 8142102

# 清单拉取 + 批量探测（不需要任何设备）
dart run tool/discover_check.dart https://你的清单地址/sites.json

# 单元测试 + UI 冒烟测试（全部使用本地假服务，不访问外网）
flutter test

# 静态检查
flutter analyze
```

国内网络建议先设置镜像：

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

### 构建 Windows 版

需要 Visual Studio 2022 **"使用 C++ 的桌面开发"** 工作负载（装 VS Community 或 Build Tools 均可；本工程仓库开发时已用 Build Tools 验证）。在 PowerShell（管理员）中：

```powershell
# 若尚未安装 Build Tools，可用 winget 一条命令装齐：
winget install Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended"

flutter build windows --release
# 产物：build/windows/x64/runner/Release/ 整个文件夹
# 主程序：build/windows/x64/runner/Release/hotshow.exe
```

分发时把 `Release` 目录整个打包（内含 dll 与 data 目录）。窗口标题与默认尺寸在 `windows/runner/main.cpp` 中调整。

### 构建 Android APK

需要 Android SDK（Android Studio 或仅命令行工具），JDK 17+：

```bash
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
# 直接安装：adb install build/app/outputs/flutter-apk/app-release.apk
```

如需分架构瘦身包：`flutter build apk --release --split-per-abi`
（产物为 `app-arm64-v8a-release.apk` 等，体积更小）

### 免工具链快速体验

若本机不想装 Visual Studio / Android Studio：
- Windows 端可用 `flutter run -d windows` 之外，还可以在本项目根目录运行 `dart run tool/api_check.dart` 验证数据功能；
- 或直接使用 Release 产物（若已随本工程提供）。

## 已验证环境

**本机已验证**（Windows 10 22H2 x64 + Flutter 3.47 stable / Dart 3.13）：

- `flutter analyze` → 0 问题
- `flutter test` → 78/78 通过；采集站检索、清单解析与探测、m3u8 解析、分片离线缓存、字幕编码/解包/偏移/存储、窄屏网格与大字号回归全部用**本地假数据**驱动，不依赖外网
- `dart run tool/source_check.dart` → 对着本地假 maccms 接口跑通「连通性自检 + 按片名检索 + 线路/集数解析」
- `dart run tool/api_check.dart` → 豆瓣数据源连通性（需要能访问豆瓣）
- **豆瓣图床实测**：同一张海报用 `Dart/x.y (dart:io)` UA 请求返回 403/418，换成浏览器 UA + `Referer: https://movie.douban.com/` 返回 200——这就是「有些剧海报加载不出来」的原因
- **字幕链路实测**：`dart run tool/subtitle_check.dart --legacy 8142102` 走通「免 Key 下载 zip（46KB）→ 解包出 srt（125KB）→ UTF-8 解码中文」，内容正确
- **OpenSubtitles 匿名搜索**：开发机 IP 在验证时被限流（403），已做成可读提示 + 「填入 API Key」入口；请求参数与响应解析另有单测覆盖，**需在真实网络环境复测**

**尚未在本机验证**：

- **APK / EXE 的实际构建与运行**：本机未安装 Visual Studio，Windows 端无法构建；Android 端构建卡在
  从 GitHub 下载 libmpv 原生库（本机网络访问不到 `objects.githubusercontent.com`，见上文构建提示）。
  代码层面 `flutter analyze` 干净，`media_kit_video` 与 `media_kit_libs_*` 已正确注册进
  `windows/flutter/generated_plugins.cmake` 与 Android 的 `GeneratedPluginRegistrant.java`；
  但**真机播放、全屏、离线缓存的实测仍需要在有代理 + 完整工具链的机器上再走一遍**。
- 采集站返回结构存在站点间差异，解析逻辑集中在 `lib/models/media_resource.dart` 与
  `lib/services/resource_service.dart`，遇到不兼容的站点改这两处即可。
- **字幕挂载的真机表现**：`SubtitleTrack.uri(本地路径)` 与 `sub-delay` 依赖 libmpv，
  Windows/Android 都支持，但外挂字幕在快进、切集后的重挂时序仍建议在真机上过一遍。

豆瓣接口与采集站接口都是非官方公开接口，若某天变化导致失效，调整对应 service 即可，UI 层无感知。

## 免责声明

- 本应用内置的只有豆瓣公开元数据接口、一个通用播放器，以及**若干公开清单源的地址**（供「自动搜索采集站」拉取候选接口）；**不内置、不存储、不代理任何影视播放源**；
- 播放能力依赖使用者通过「自动搜索」或手动添加的第三方采集站接口。这些站点多为非官方来源，其内容合法性、可用性与版权状态需由使用者自行判断，**请仅用于学习交流，勿用于商业用途**；
- 离线缓存功能仅是把使用者指定地址的分片暂存到本机，请勿用于传播他人作品；
- 梗概、海报、短评等版权归原作者与豆瓣所有；应用不向任何服务器上传用户数据，所有历史记录、站点配置、播放进度仅保存在本地。
