# 红果短剧高清抓取（hongguo_hd）

把红果短剧网页端的 **720p 加密 DASH** 解密成可播放 MP4 的命令行工具。
完整逆向过程见 [`docs/红果高清探测.md`](../../docs/红果高清探测.md) 第六、七节。

> 仅供个人学习研究。输出目录 `out/` 已 gitignore，成片不入库；请勿传播或商用。

## 为什么需要它

红果网页端对访客只给 360p 试看；480p/720p 走 CENC-AES-CTR 加密 DASH，
密钥由网页播放器内部的 jsvmp VM 派生。本工具不离线逆 VM，而是**驱动浏览器里 SDK 自己的
解密播放器**，把它喂给 MediaSource 的明文分片收走，再 remux 成片。

## 依赖

- Node.js ≥ 18
- 本机 **Edge 或 Chrome**（puppeteer-core 复用本机浏览器，不下载 Chromium）
- `npm install`（装 `puppeteer-core` + `@ffmpeg-installer/ffmpeg`，ffmpeg 二进制打进 npm 包）

```bash
cd tool/hongguo_hd
npm install
```

浏览器不在默认路径时，设 `BROWSER_PATH` 环境变量指向可执行文件。

## 用法

```bash
# 抓某剧第 1 集（自动从详情页取 vid），720p
node decrypt.cjs <series_id>

# 指定单集 item_id（vid_list 里的 id）
node decrypt.cjs <series_id> <item_id>

# 480p / 自定义输出目录 / 保留中间分片
node decrypt.cjs <series_id> <item_id> --def 480p --out D:\videos --keep
```

- `series_id`：详情页 / 榜单里的剧集 id（`/detail?series_id=…`）。
- `item_id`：单集 vid，不传则自动取第 1 集。
- 输出：`out/hongguo_<series>_<item>_<def>.mp4`（H.264 + AAC，`-c copy` 无损 remux）。

`tool/hongguo_hd_probe.dart` 可先查某剧各档位元数据与 vid：

```bash
dart run tool/hongguo_hd_probe.dart <series_id>
```

## 工作原理（三步绕过）

1. **访问层**：受保护接口只在裸域 `hongguoduanju.com` 匿名开放（`www` 返回 405）。
2. **绕门禁**：捕获 rspack `__webpack_require__`
   （`self.rspackChunkhongguo.push([['__cap'],{},req=>self.__req=req])`），
   直接调 `req('wh').createEncryptedPlayer(config)`——它本身不查页面的 `browserAllowed` 门禁。
3. **绕反劫持**：SDK 用 `isNativeFunction` 检查 `SourceBuffer.appendBuffer` 是否原生，
   直接 hook 会报「MSE被劫持」。spoof `Function.prototype.toString` 让 hook 伪装成原生函数。

随后 `playbackRate=4` 连续播到片尾，按 `hdlr` box 区分视频/音频轨，ffmpeg remux。

## 已知坑

- 音频列表必须嵌在 `DASHPlugin.dashOpts.dynamic_video.dynamic_audio_list`（放外层同级就没有音频轨）。
- 音频 `codec_type` 用 `mp4a`（接口误返 `h264`）。
- 接口地址约 1 小时过期；工具每次现取 play-info，无需缓存。
- 站点 JS 改版可能导致模块 id（`wh`/`ge`）或 config 字段变化，届时按文档第七节重新定位。
