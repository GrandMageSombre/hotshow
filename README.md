# 热剧速览 (HotShow)

实时热播 **电视剧 / 短剧 / 动漫** 聚合搜索应用，一套 Flutter 代码同时支持 **Windows** 和 **Android**。

![平台](https://img.shields.io/badge/平台-Windows%20%7C%20Android-blue) ![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)

## 功能

| 功能 | 说明 |
|------|------|
| 📺 热播榜单 | 电视剧（热门/国产剧/美剧/日剧/韩剧/综艺/纪录片）、短剧（热门短剧/网络剧）、动漫（热门动漫/日本动画/国漫） |
| 🔄 实时更新 | 进入应用自动拉取最新榜单；每 10 分钟自动刷新当前页面；支持下拉刷新与手动刷新按钮；列表无限加载更多 |
| 🔍 自主搜索 | 关键词实时搜索（输入 600ms 自动联想搜索），覆盖电视剧/短剧/动漫/电影，显示评分、年份、地区、演员 |
| 🕘 历史记录 | 搜索历史（可单条删除/一键清空，点击直接重搜）+ 浏览历史（最近看过 100 条，点击回看详情），本地持久化存储 |
| ℹ️ 详情页 | 海报、评分、类型/地区/首播/集数、导演/主演、剧情简介、豆瓣热门短评，一键跳转豆瓣网页 |

## 技术实现

- **框架**: Flutter (Material 3)，单代码库 → Android APK + Windows EXE
- **数据源**: 豆瓣公开数据（未官方授权，仅供学习）
  - 榜单：`m.douban.com/rexxar/api/v2/subject_collection/*`（网页端集合接口）
  - 短剧/网剧/动漫标签聚合：`frodo.douban.com/api/v2/tv/recommend`（App 端接口，HMAC-SHA1 请求签名）
  - 搜索：`frodo.douban.com/api/v2/search/subjects`
  - 详情：`frodo.douban.com/api/v2/tv/{id}` / `movie/{id}`
- **本地存储**: `shared_preferences`（Android 应用私有目录 / Windows 用户配置目录）
- **状态管理**: 轻量 ChangeNotifier + StatefulWidget，无重型依赖

## 项目结构

```
lib/
├── main.dart                  # 应用入口 + 底部导航壳
├── models/
│   └── show_item.dart         # 影视条目/详情模型（三种来源 JSON 归一化）
├── services/
│   ├── api_client.dart        # HTTP 层：frodo 签名客户端 + rexxar 客户端 + 统一错误
│   ├── show_service.dart      # 业务数据层：榜单/搜索/详情（不依赖 Flutter，可单独测试）
│   └── history_store.dart     # 搜索历史 + 浏览历史（本地持久化）
├── pages/
│   ├── home_page.dart         # 三个分类 Tab + 子榜单切换 + 实时刷新
│   ├── search_page.dart       # 搜索页（防抖联想 + 搜索历史）
│   ├── history_page.dart      # 历史记录页
│   └── detail_page.dart       # 详情页
└── widgets/
    ├── show_card.dart         # 海报卡片（评分角标）
    └── common_views.dart      # 错误重试/空态/列表尾组件
tool/api_check.dart            # 数据层真实接口集成测试（dart run 直跑）
test/widget_test.dart          # UI 冒烟测试（注入假数据，不访问网络）
```

## 构建与运行

前置条件：[Flutter SDK](https://docs.flutter.cn/get-started/install)（建议 3.35+，本工程在 3.47 上开发验证）。

### 直接安装（Android）

本项目已构建好发行版 APK：

```
releases/热剧速览-v1.0.0-android.apk   （约 50MB，release 签名可直接安装）
```

传到手机上点击安装即可（需允许"安装未知来源应用"）。

### 本地开发

```bash
flutter pub get

# 本地调试运行（连接的设备/模拟器）
flutter run

# 数据层真实接口连通性验证（不需要任何设备）
dart run tool/api_check.dart

# UI 冒烟测试
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

- Windows 10 22H2 x64 + Flutter 3.38 stable（`flutter analyze` 0 问题、`flutter test` 通过、`dart run tool/api_check.dart` 7/7 数据源连通）
- 豆瓣接口为非官方公开接口，若某天接口变化导致失效，调整 `lib/services/api_client.dart` 与 `show_service.dart` 即可，UI 层无感知。

## 免责声明

本应用仅调用豆瓣公开网页/App 接口获取**元数据**（片名、评分、简介、海报），不提供任何影视内容的播放或下载，不存储用户数据到任何服务器。仅供学习交流，请勿用于商业用途。
