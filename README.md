# 热剧速览 (HotShow)

> **使用声明**：本项目是 **umena 的个人自用软件**，不是商业产品，**禁止任何形式的商业使用**
> （售卖、出租、捆绑、代运营、广告变现等）。详见 [LICENSE](LICENSE)。
> 应用内每个版本首次启动都会弹出该声明，首页右上角「i」可随时重看。

实时热播 **电视剧 / 电影 / 短剧 / 动漫** 聚合搜索应用，一套 Flutter 代码同时支持 **Windows / Android / macOS / iOS**。
发现好剧 → 一键检索完整片源 → 内置播放器直接看，支持选集、倍速与离线缓存。

![平台](https://img.shields.io/badge/平台-Windows%20%7C%20Android%20%7C%20macOS%20%7C%20iOS-blue) ![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)

## 功能

| 功能 | 说明 |
|------|------|
| 📺 热播榜单 | 「全部」聚合流（全部分类的榜单轮播交织成一列，翻页去重）+ 电视剧（热门/国产剧/美剧/日剧/韩剧/综艺/纪录片）、**电影**（热门/正在上映/即将上映/TOP250/口碑榜）、短剧（热门短剧/网络剧）、动漫（热门动漫/日本动画/国漫/欧美动画） |
| 🏷️ 多维筛选 | 「类型 + 地区 + 年份」三级筛选，参数以豆瓣 `tags` 逗号组合传给接口：电视剧/全部（喜剧/战争/古装…16 种）、电影（喜剧/动作/科幻/战争…14 种）、短剧（短剧专属池：古装/甜宠/职场…）、动漫（热血/治愈/搞笑/校园…）；地区含中国大陆/美国/日本/韩国等 8 个，年份近 12 年。筛选组合如「喜剧 · 美国 · 2024」「短剧 · 古装 · 2024」均实测有效 |
| 🔄 实时更新 | 进入应用自动拉取最新榜单；每 10 分钟自动刷新当前页面；支持下拉刷新与手动刷新按钮；列表无限加载更多 |
| 🔍 自主搜索 | 关键词实时搜索（输入 600ms 自动联想搜索），覆盖电视剧/电影/短剧/动漫，显示评分、年份、地区、演员；也可直接点类型条按类型浏览 |
| 🕘 历史记录 | 搜索历史（可单条删除/一键清空，点击直接重搜）+ 浏览历史（最近看过 100 条，点击回看详情），本地持久化存储 |
| ℹ️ 详情页 | 海报、评分、类型/地区/首播/集数、导演/主演、剧情简介、豆瓣热门短评，一键跳转豆瓣网页 |
| ▶️ 在线播放 | 详情页一键到已配置的采集站检索「完整资源」（多线路 / 全集），内置 media_kit（libmpv）播放器：选集、切线路、倍速、全屏、自动连播 |
| ⬇️ 离线缓存 | 单集或整条线路的 m3u8 分片抓到本地并重写为本地播放列表，断网可看；播放进度本地记忆，下次进入自动续播 |
| 🗄️ 采集站管理 | 站点可增删改、启停、连通性自检；**工程不写死任何影视站点地址**，站点由自动搜索或手动填写得到 |
| 🔎 自动搜索采集站 | **不用填任何地址**，点一下就自动拉取内置的公开清单源并解析出候选采集接口（也支持纯文本 / JSON 数组 / `{"sites":[…]}` / TVBox 风格配置，或手动粘贴），并发探测后标出可用/不可用/已添加，勾选即批量导入 |
| 💬 在线字幕 | 播放页一键搜索 OpenSubtitles（免登录可搜，匿名有频率限制，可填免费 API Key），下载 zip 自动解包、GBK 自动转 UTF-8；支持粘贴字幕直链、管理本剧字幕、时间轴 ±0.5s 实时微调，换集自动重挂 |


## 技术实现

- **框架**: Flutter (Material 3)，单代码库 → Android APK / Windows EXE / macOS .app / iOS（自签）
- **元数据源**: 豆瓣公开数据（未官方授权，仅供学习）
  - 榜单：`m.douban.com/rexxar/api/v2/subject_collection/*`（网页端集合接口）
  - 短剧/网剧/动漫标签聚合：`frodo.douban.com/api/v2/tv/recommend`（App 端接口，HMAC-SHA1 请求签名）
  - 搜索：`frodo.douban.com/api/v2/search/subjects`
  - 详情：`frodo.douban.com/api/v2/tv/{id}` / `movie/{id}`
- **播放源**: 第三方影视采集站（maccms / 苹果CMS 的 `api.php/provide/vod` 接口），按片名检索后解析 `vod_play_from` + `vod_play_url` 得到多线路、全部分集的播放地址；站点通过「自动搜索」从公开清单源发现，代码里不写死任何站点地址
- **播放器**: [`media_kit`](https://github.com/media-kit/media-kit)（libmpv），Windows 与 Android 双端原生播放 HLS/m3u8，播放/进度/全屏由 `media_kit_video` 的 AdaptiveVideoControls 承担，选集、倍速、缓存按钮为自绘
- **离线缓存**: 自研 m3u8 解析（master 码流选择、`EXT-X-KEY` 逐分片密钥、`EXT-X-MAP`）+ 4 并发分片下载 + 本地播放列表重写，落盘后断网可播
- **在线字幕**: OpenSubtitles（`api.opensubtitles.com/api/v1`）+ 免 Key 的旧站下载通道 `dl.opensubtitles.org/en/download/sub/{legacy_id}`；自研 zip/gzip 解包（中央目录 + stored/deflate）、编码识别（UTF-8 / UTF-16 BOM / GBK）、字幕统一转 UTF-8 落盘；时间轴调整走 libmpv 的 `sub-delay` 实时生效，不支持时回退到重写字幕文件
- **网络图片**: 豆瓣图床的 WAF 对图片请求有两条硬规则（都返回 403/418）——
  User-Agent 必须是浏览器，且**请求里只能有一个 UA 头**。而 `dart:io` 的
  `HttpClient.getUrl()` 会先自动塞 `Dart/x.y (dart:io)`，Flutter 的 `Image.network`
  再用 `headers.add()` 加浏览器 UA，结果请求带着**两个 UA** 被 WAF 拒掉——这才是
  「海报加载不出来」的真正根因（用 `headers.set()` 覆盖即可，见 `widgets/remote_image.dart`）。
  在此之上按「尝试链」降级：`img1/2/3/9.doubanio.com` → 原域名 `http://` → 裸请求，
  每步 12s 超时看门狗，全失败记 10 分钟负缓存；**长按任意封面**可弹出诊断
  （地址 / 错误 / 尝试链 / 版本）；`dart run tool/image_probe.dart` 可在电脑上复现四种头组合。
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

- **在线获取字幕**：默认用当前片名搜索 OpenSubtitles；如果豆瓣别名里有英文名，会**优先用英文名**起搜——
  多数中文字幕是按英文片名发布的。选中一条后自动下载、解包、转码并挂到画面上；
- **本地与直链**：粘贴 `.srt` / `.ass` / `.vtt` / `.zip` / `.gz` 的字幕直链导入；这里也能管理本剧已下载的字幕、填写 OpenSubtitles 的免费 API Key；
- **时间轴**：字幕面板里「提前 0.5s / 延后 0.5s」在面板内原地生效（libmpv `sub-delay`），可一键恢复，偏移会记住；
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
│   ├── genre.dart             # 片源类型（Genre）+ 四张类型表（电视剧/电影/短剧/动漫）
│   ├── facet.dart             # 多维筛选（FilterSelection：类型/地区/年份 → tags）
│   ├── subtitle.dart          # 字幕搜索结果 / 本地字幕记录模型
│   └── source_site.dart       # 采集站配置模型（纯 Dart，可 dart run 直用）
├── services/
│   ├── api_client.dart        # HTTP 层：frodo 签名客户端 + rexxar 客户端 + 统一错误
│   ├── remote_ua.dart         # 统一的浏览器 User-Agent（豆瓣图床/字幕站都认它）
│   ├── show_service.dart      # 豆瓣业务层：榜单/筛选/搜索/详情（不依赖 Flutter，可单独测试）
│   ├── paged_show_list.dart   # 筛选+分页状态机（三个列表页共用，带请求代号）
│   ├── resource_service.dart  # 采集站检索层：多站并发搜索 + 片名匹配排序
│   ├── source_store.dart      # 采集站配置持久化
│   ├── source_discovery.dart  # 采集站自动发现：清单解析 + 并发探测
│   ├── subtitle_service.dart  # 字幕业务层：搜索/下载/解包/转码/落盘/偏移
│   ├── subtitle_message.dart  # 字幕异常 → 用户可读文案（带 debug 日志）
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
│   ├── home_page.dart         # 四个分类 Tab（全部/电视剧/短剧/动漫）+ 子榜单切换 + 实时刷新
│   ├── search_page.dart       # 搜索页（防抖联想 + 搜索历史 + 按类型浏览）
│   ├── genre_page.dart        # 单个类型的列表页（详情页类型标签跳转，可再筛地区/年份）
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
tool/image_probe.dart          # 豆瓣图床 WAF 探针：四种请求头组合实测（dart run 直跑）
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

本项目已构建好发行版：

```
releases/spgj-v1.5.0-android.apk       （94MB，电影分类 + 类型/地区/年份筛选 + macOS 平台，versionCode 8）
releases/spgj-v1.4.0-android.apk       （94MB，全界面类型分类 + 动漫海报/国漫修复，versionCode 7）
releases/spgj-v1.3.0-android.apk       （94.0MB，「全部」聚合分类）
releases/spgj-v1.2.2-android.apk       （94.0MB，修复图片加载根因：双 User-Agent，versionCode 5）
releases/spgj-v1.2.2-windows-x64.zip   （32.1MB，同上，解压后双击 hotshow.exe，含 VC++ 运行库）
releases/spgj-v1.2.1-android.apk       （94.0MB，图片加载降级链 + 长按封面诊断）
releases/spgj-v1.2.0-android.apk       （93.9MB，图片/网格修复 + 在线字幕）
releases/spgj-v1.1.0-android.apk       （92.7MB，含播放器与自动搜索）
releases/spgj-v1.0.0-android.apk       （49.7MB，旧版：仅榜单/搜索/详情，无播放能力）
```

> v1.2.0 的 APK 已用 `flutter build apk --release` 重新打包（`versionCode=3 / versionName=1.2.0`，
> minSdk 24 / targetSdk 36）。
>
> 注：仓库的 `.gitignore` 忽略了 `releases/`，这些 APK 只存在于开发机本地，
> 新克隆仓库后需要自己构建，或从原始发布渠道获取。

传到手机上点击安装即可（需允许"安装未知来源应用"），或用 adb：

```bash
adb install releases/spgj-v1.2.0-android.apk
```

> v1.1.0 体积变大是因为内置了 3 个 ABI 的 `libmpv.so`（arm64-v8a / armeabi-v7a / x86_64，每个约 12MB）。
> 只想出精简包可以按 ABI 拆分：`flutter build apk --release --split-per-abi`。

### 构建 Windows 桌面版

需要 Visual Studio（2019 / 2022 / 2026 均可，Insiders 预览版也支持）+ 下列组件。
Flutter 通过 `vswhere` 检查 **`Microsoft.VisualStudio.Component.VC.Tools.x86.x64`** 与
**`Microsoft.VisualStudio.Component.VC.CMake.Project`**，缺任意一个都会报
`Unable to find suitable Visual Studio toolchain`。

> 仓库根目录带了 **`.vsconfig`**：在 **Visual Studio Installer → 「更多」→「导入配置」** 里选中它，
> 会自动勾好下面这些组件，不用手工找。

1. 打开 **Visual Studio Installer**（开始菜单搜索，或在 VS 里点 **工具 → 获取工具和功能…**）→ **修改**；
2. 工作负载勾选「**使用 C++ 的桌面开发**」；
3. 右侧「安装详细信息」里确认这三项都被勾选：
   - MSVC v14x - VS 20xx C++ x64/x86 生成工具
   - **用于 Windows 的 C++ CMake 工具**（`VC.CMake.Project`，**最容易漏**，注意是「用于」不是「适用于」）
   - **Windows 11 SDK**（10.0.26100.x 或 10.0.28000.x，分类在「SDK、库和框架」）
4. 安装完成后执行：

```powershell
flutter build windows --release
```

产物在 `build/windows/x64/runner/Release/`：`hotshow.exe` + `flutter_windows.dll` + `data/` +
`media_kit_libs_windows_video` 的 DLL。**要整个目录一起分发**，只拷 exe 会缺运行库。

> **踩过的两个坑**
>
> 1. **CMake 4.x 会把安装目录设成 `C:\Program Files\<app>`**：官方模板用
>    `CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT` 判断，但 CMake 4 不再定义这个变量，
>    结果 `runner\Release` 里只有一个 exe，DLL 和 `data\` 全被装去 Program Files。
>    本仓库的 `windows/CMakeLists.txt` 已加兜底判断，安装目录固定在 `runner\<配置>`。
> 2. **首次构建下载 libmpv / ANGLE 压缩包会校验 MD5 失败**（代理返回半截数据时）：
>    可先用任意可达的镜像手动下载，放到 `build/windows/x64/` 下（文件名必须一致）：
>    - `mpv-dev-x86_64-20230924-git-652a1dd.7z`（MD5 `a832ef24b3a6ff97cd2560b5b9d04cd8`）
>    - `ANGLE.7z`（MD5 `e866f13e8d552348058afaafe869b1ed`）
>
>    CMake 检测到文件存在且 MD5 匹配就会跳过下载：
>    `https://gh-proxy.com/https://github.com/media-kit/libmpv-win32-video-build/releases/download/2023-09-24/...`

> 命令行安装（管理员 PowerShell，最快）：
>
> ```powershell
> & "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vs_installer.exe" modify `
>   --installPath "D:\vs\18\Insiders" `
>   --add Microsoft.VisualStudio.Component.VC.CMake.Project `
>   --add Microsoft.VisualStudio.Component.Windows11SDK.26100 `
>   --passive --norestart
> ```
>
> 自检：`vswhere -prerelease -products * -requires Microsoft.VisualStudio.Component.VC.CMake.Project -property installationPath`
> 有输出才说明 CMake 组件装上了；`C:\Program Files (x86)\Windows Kits\10\Include` 下存在
> `10.0.xxxxx.0` 目录才说明 Windows SDK 装上了。

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

### 构建 macOS 版

**必须在 macOS 上构建**（Xcode 工具链无法在 Windows 上运行）。仓库里已含 `macos/` 工程，
无需再 `flutter create`。

> iOS 也是同样限制，但 iOS 可以**把编译外包给 GitHub 的免费 macOS runner**，
> Windows 只负责签名安装 —— 见下一节「在 iPhone 上运行」。macOS 桌面版目前没有这种托管编译，
> 只能在 Mac 上出包。

1. 装 Xcode（15+，含命令行工具：`xcode-select --install`）；
2. 在项目根目录执行：

```bash
flutter pub get
flutter build macos --release
```

产物：`build/macos/Build/Products/Release/HotShow.app`（可直接拖进「应用程序」）。

已为本项目改好的 macOS 配置（如换机器重新 `flutter create` 注意保留）：

| 文件 | 改动 | 原因 |
|------|------|------|
| `macos/Runner/DebugProfile.entitlements` / `Release.entitlements` | 增加 `com.apple.security.network.client` | App Sandbox 默认**禁止出网**，不加则所有接口/海报都请求失败 |
| `macos/Runner/Info.plist` | `NSAppTransportSecurity.NSAllowsArbitraryLoads = true` | 采集站大量是 http 明文接口，ATS 默认拦截 |
| `macos/Runner/Info.plist` | `CFBundleDisplayName = 热剧速览` | 程序坞/访达显示中文名 |
| `macos/Runner/Configs/AppInfo.xcconfig` | `PRODUCT_NAME = HotShow` | 可执行文件名（保持 ASCII） |
| `macos/Runner/MainFlutterWindow.swift` | 初始 1100×760、最小 900×640 | 桌面版按手机宽度开局会只剩两列海报 |

分发说明：

- 本地自用：`flutter build macos --release` 后直接运行，无需签名；
- 分发给别人：需要 Apple Developer 账号做 **Developer ID 签名 + 公证（notarization）**，
  否则对方首次打开会被 Gatekeeper 拦（右键「打开」可绕过）。
  `NSAllowsArbitraryLoads` 只影响 App Store 审核，**Developer ID 直接分发不受此限制**。
- 应用图标：`macos/Runner/Assets.xcassets/AppIcon.appiconset/` 目前是 Flutter 默认图标，
  换图标需要 `AppIcon.icns`（macOS 上用 `iconutil` 从 png 集合生成）。

### 在 iPhone 上运行（没有 Mac 也能装）

**硬限制**：iOS 应用必须在 macOS 上编译（Xcode 只能在 Mac 跑），
但**签名和安装可以在 Windows 上完成**。所以只需要一台 Windows 电脑 + iPhone。

仓库已带工作流 `.github/workflows/ios-unsigned-ipa.yml`：用 GitHub 免费的 macOS runner
编出**未签名 .ipa**，你在本机用自己的 Apple ID 签名安装。

1. **出包**：GitHub 仓库 → **Actions** → 左侧 `Build unsigned iOS IPA` → **Run workflow**；
   约 5~10 分钟（首次要下载 Flutter SDK，之后有缓存会快很多）后，在运行详情页底部下载 **`hotshow-unsigned-ipa.zip`** → **先解压**，
   里面那个 `hotshow-unsigned.ipa` 才是要拖进 Sideloadly 的文件（直接把 zip 拖进去会失败）。
   也可以在本地打 tag 推送（`git tag v1.6.0 && git push origin v1.6.0`）自动触发。
2. **装工具**（Windows）：Sideloadly 需要 Apple 的「Apple Mobile Device」驱动，二选一即可 ——
   Win11/10 装微软商店的 **Apple Devices**（更轻），或装 [iTunes](https://www.apple.com/itunes/)；
   再装 [Sideloadly](https://sideloadly.io/)。首次运行建议用管理员权限（装驱动）。
3. **签名安装**：iPhone 用数据线连电脑并在手机上点「信任」→ 打开 Sideloadly →
   把 `hotshow-unsigned.ipa` 拖进去 → 填自己的 Apple ID（普通账号即可）→ Start。
4. **信任证书**：iPhone → 设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任你的 Apple ID。
5. 桌面上就有「热剧速览」了。

**免费 Apple ID 的限制**（重要）：

| 项目 | 免费账号 | 付费开发者账号（$99/年） |
|------|----------|--------------------------|
| 有效期 | **7 天**，过期打不开，需重新签名 | 1 年 |
| 同时安装 | 最多 3 个自签 App | 100 台设备 |
| 续签 | 每 7 天用同一台电脑重签（[AltStore](https://altstore.io/) 需电脑上常驻 AltServer 且同一 Wi-Fi，约 1~3 天唤醒一次才能自动续） | 不用 |
| 分发 | 只能装自己手机，**不支持 TestFlight** | 可用 TestFlight 邀请他人（90 天一轮） |

> 如果你的 iPhone 上没有电脑可用：iOS 不允许纯手机侧载，必须借一台 Windows/Mac
> （或云 Mac）完成一次签名安装，之后每 7 天仍需连一次同一台电脑重签。

**iOS 16 及以上必须先开「开发者模式」**：装完第一次点开若提示「需要开发者模式」，
到 iPhone → 设置 → 隐私与安全性 → 开发者模式 → 打开并重启手机（这个开关只有连过
Xcode/Sideloadly 之后才会出现）。

**常见问题**

| 现象 | 原因 / 处理 |
|------|-------------|
| 点开闪退、图标变灰 | 7 天证书到期：用同一台电脑重新 Sideloadly 覆盖安装即可，App 内数据会保留 |
| Sideloadly 提示密码错误 | Apple ID 开了两步验证：去 appleid.apple.com 生成「App 专用密码」，用它代替主密码 |
| 提示 "Unable to install" | 手机上没点「信任此电脑」；或驱动没装（装 iTunes / Apple Devices） |
| 提示已达 3 个 App 上限 | 免费账号最多同时签 3 个；删掉其它自签 App 或等 7 天过期后再签 |

> 安全提示：签名时 Apple ID 会交给 Sideloadly 换取签名证书，建议用 **App 专用密码**，
> 并且只在自己的电脑上操作；不要用「企业签名 / 共享证书」类服务（违反 Apple 条款，
> 证书易被批量吊销），也不要在陌生电脑上登录 Apple ID。
>
> 不需要额外 entitlements：本 App 只用 shared_preferences / path_provider / media_kit /
> url_launcher，Sideloadly 重签时会自动注入 `application-identifier` 与 `get-task-allow`。

**iOS 已配好的项**：`Info.plist` 加 `NSAppTransportSecurity`（采集站多为 http）、
`UIBackgroundModes=audio`（已声明后台音频，锁屏是否继续播放取决于 media_kit 的
AVAudioSession 配置，若锁屏即暂停属已知限制）、中文显示名「热剧速览」；
部署目标 iOS 15.0（Flutter 模板默认），Bundle ID `com.hotshow.hotshow`。

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
- `flutter test` → 81/81 通过；采集站检索、清单解析与探测、m3u8 解析、分片离线缓存、字幕编码/解包/偏移/存储、窄屏网格与大字号回归全部用**本地假数据**驱动，不依赖外网
- `dart run tool/source_check.dart` → 对着本地假 maccms 接口跑通「连通性自检 + 按片名检索 + 线路/集数解析」
- `dart run tool/api_check.dart` → 豆瓣数据源连通性（需要能访问豆瓣）
- **豆瓣图床实测**：同一张海报用 `Dart/x.y (dart:io)` UA 请求返回 403/418，换成浏览器 UA + `Referer: https://movie.douban.com/` 返回 200——这就是「有些剧海报加载不出来」的原因
- **字幕链路实测**：`dart run tool/subtitle_check.dart --legacy 8142102` 走通「免 Key 下载 zip（46KB）→ 解包出 srt（125KB）→ UTF-8 解码中文」，内容正确
- **OpenSubtitles 匿名搜索**：开发机 IP 在验证时被限流（403），已做成可读提示 + 「填入 API Key」入口；请求参数与响应解析另有单测覆盖，**需在真实网络环境复测**

**已验证 / 尚未验证**：

- **Android APK 构建**：已在本机成功构建（`flutter build apk --release`，93.9MB，219.5s），
  libmpv 的 4 个 ABI jar 能正常下载；真机播放、全屏、离线缓存仍建议再走一遍。
- **Windows 桌面版构建**：已在本机成功构建（VS 2026 Insiders 18.12 + Windows 11 SDK 26100，
  首次 81.5s / 增量 16.5s），`hotshow.exe` 的 FileVersion/ProductVersion 为 `1.2.0+3`，
  已打成 `releases/spgj-v1.2.0-windows-x64.zip`（含 34 个文件，内置 VC145 运行库）。
  真机播放、全屏、离线缓存仍建议在 Windows 上再走一遍。
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
