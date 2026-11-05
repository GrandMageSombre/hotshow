# 直播精选目录的生成流程

`assets/live_channels.json`（App 里「直播」页的频道表）不是手写的，是这几个脚本跑出来的。

公开 IPTV 源会烂得很快——实测 3156 个频道地址里只有三成能播，
号称「1300 个源全部有效」的合集实测 1298 条里只有 7 条能播。
所以流程是：**全量检测 → 归并 → 白名单收敛 → 复验**，只把活着的写进 App。

## 用法

```bash
# 1. 全量检测（约 10 分钟，输出 out/result.jsonl）
python tool/live_verify/verify.py

# 2. 生成精选目录（会重写 ../../assets/live_channels.json）
python tool/live_verify/curate.py
```

## verify.py 在验什么

不是「能拉回 m3u8 就算活」——那样会放进来一堆假活。每个地址要过四关：

1. 主 m3u8 拉得回来；
2. `#EXT-X-KEY` 的密钥地址拉得回来（AES-128 流拿不到 key 会黑屏）；
3. master playlist 的话，子列表也要拉得回来；
4. 抽首/中/末 **3 个分片**都能拉——只验首片会漏掉「后续分片全死」的直播流。

**请求头必须和 App 完全一致**，否则会「测着能播、用户播不了」：

- UA 用 `lib/services/remote_ua.dart` 里的 `kBrowserUserAgent` 原文（Windows Chrome）；
- 直播**不补**同域 Referer（`PlayerPage._headersFor` 在 `isLive` 时就是这么做的），
  只有源自己声明了 `http-referrer` 才带。

## curate.py 在做什么

1. **同台归并**：`CCTV-1` / `CCTV1` / `CCTV-1 综合` / `CCTV1 HD` 归一成一台，
   按响应速度排序，最多留 3 个地址（第一个当主地址，其余在播放器里是备用线路）；
2. **分类**：央视 / 地方 / 国外 / 体育，靠台名关键词 + 来源；
3. **白名单收敛**：只留省卫视和知名台，把「浙江遂昌」「GS Home Shopping」
   这类本地台/购物台剔掉；
4. **规范化台名**：CCTV 系列补上「综合/财经/综艺」这类中文名。

## 什么时候要重跑

频道地址一般几个月就换一批。用户反馈「某个台打不开」且不是个例时，
重跑一遍即可。跑完记得同步 `docs/直播源精选.md` 里的实测数字。

## 注意

- 这几个脚本依赖本机 Python 3 + 能访问 GitHub / iptv-org，不随 App 分发；
- `out/` 里是中间结果，不入库；
- 脚本里的源清单（`SOURCES`）要和 `lib/services/iptv_service.dart` 的 `kIptvSources`
  保持一致，否则两边会选出不同的台。
