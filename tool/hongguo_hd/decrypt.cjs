#!/usr/bin/env node
/**
 * 红果短剧高清（720p）抓取 + 解密 + remux 成片。
 *
 * 原理（详见 docs/红果高清探测.md 第六、七节）：
 *  1. 受保护播放接口只在裸域 hongguoduanju.com 匿名开放（www 返回 405）。
 *  2. 用 puppeteer 驱动本机 Edge/Chrome 打开播放页，捕获 rspack __webpack_require__，
 *     直接调 SDK 的 createEncryptedPlayer（绕过页面 browserAllowed 门禁）让它解密到 MSE。
 *  3. hook SourceBuffer.appendBuffer 收明文 fMP4；SDK 有 isNativeFunction 反劫持，
 *     用 Function.prototype.toString 伪装成原生函数绕过。
 *  4. 连续加速播到片尾收全视频/音频分片，ffmpeg -c copy remux 成 mp4。
 *
 * 用法：
 *   node decrypt.cjs <series_id> [item_id] [--def 720p] [--out DIR] [--keep]
 *   不传 item_id 时自动抓详情页取第 1 集 vid。
 *
 * 依赖：puppeteer-core、@ffmpeg-installer/ffmpeg（见 package.json），本机 Edge/Chrome。
 * 仅供个人学习研究；输出目录 out/ 已 gitignore，成片不入库。
 */
'use strict';
const puppeteer = require('puppeteer-core');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

// ---- 参数 ----
const argv = process.argv.slice(2);
const positional = argv.filter((a) => !a.startsWith('--'));
const opt = (name, dflt) => {
  const i = argv.indexOf('--' + name);
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : dflt;
};
const seriesId = positional[0];
let itemId = positional[1] || '';
const definition = opt('def', '720p');
const outDir = path.resolve(opt('out', path.join(__dirname, 'out')));
const keep = argv.includes('--keep');
if (!seriesId) {
  console.error('用法: node decrypt.cjs <series_id> [item_id] [--def 720p] [--out DIR] [--keep]');
  process.exit(1);
}

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0';
const BASE = 'https://hongguoduanju.com'; // 裸域，www 会 405

function detectBrowser() {
  if (process.env.BROWSER_PATH && fs.existsSync(process.env.BROWSER_PATH)) return process.env.BROWSER_PATH;
  const candidates = [
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    '/usr/bin/microsoft-edge',
    '/usr/bin/google-chrome',
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  ];
  for (const c of candidates) if (fs.existsSync(c)) return c;
  throw new Error('找不到 Edge/Chrome，请设 BROWSER_PATH 环境变量');
}

function detectFfmpeg() {
  try {
    return require('@ffmpeg-installer/ffmpeg').path;
  } catch (_) {
    return 'ffmpeg'; // 退回 PATH
  }
}

// 自动取第 1 集 vid
async function autoItemId() {
  const res = await fetch(`${BASE}/detail?series_id=${seriesId}`, { headers: { 'User-Agent': UA } });
  const html = await res.text();
  const m = html.match(/"vid_list"\s*:\s*\[\s*"(\d+)"/);
  if (!m) throw new Error('详情页没解析到 vid_list，请手动传 item_id');
  return m[1];
}

// 按 hdlr box 区分视频/音频轨
function trackKind(file) {
  const b = fs.readFileSync(file);
  const i = b.indexOf('hdlr', 0, 'latin1');
  if (i >= 0) {
    const h = b.toString('latin1', i + 8, i + 12);
    if (h === 'vide') return 'video';
    if (h === 'soun') return 'audio';
  }
  return b.indexOf('mp4a', 0, 'latin1') >= 0 ? 'audio' : 'video';
}

(async () => {
  if (!itemId) {
    itemId = await autoItemId();
    console.log(`自动取第 1 集 vid: ${itemId}`);
  }
  fs.mkdirSync(outDir, { recursive: true });
  const capDir = path.join(outDir, `.capture_${itemId}`);
  fs.mkdirSync(capDir, { recursive: true });
  const browserPath = detectBrowser();
  const ffmpeg = detectFfmpeg();
  console.log(`browser: ${browserPath}\nffmpeg:  ${ffmpeg}\nseries=${seriesId} item=${itemId} def=${definition}`);

  const browser = await puppeteer.launch({
    executablePath: browserPath,
    headless: 'new',
    args: ['--no-sandbox', '--disable-blink-features=AutomationControlled', '--lang=zh-CN', '--autoplay-policy=no-user-gesture-required', '--mute-audio'],
    defaultViewport: { width: 1280, height: 900 },
  });
  const page = await browser.newPage();
  await page.setUserAgent(UA);
  await page.evaluateOnNewDocument(() => Object.defineProperty(navigator, 'webdriver', { get: () => false }));

  const files = {}, counts = {}, seen = {};
  await page.exposeFunction('__sendChunk', (kind, b64) => {
    if (!files[kind]) { files[kind] = fs.openSync(path.join(capDir, `dec_${kind}.m4s`), 'w'); counts[kind] = 0; }
    const buf = Buffer.from(b64, 'base64');
    const key = kind + ':' + crypto.createHash('sha1').update(buf).digest('hex');
    if (seen[key]) return;
    seen[key] = 1;
    fs.writeSync(files[kind], buf);
    counts[kind] += buf.length;
  });
  await page.exposeFunction('__log', (m) => console.log('[page]', String(m).slice(0, 160)));

  // hook appendBuffer + 原生伪装（绕过 SDK 的 isNativeFunction 反劫持）
  await page.evaluateOnNewDocument(() => {
    const SB = window.SourceBuffer;
    if (!SB) return;
    const ids = new WeakMap();
    let n = 0;
    const ap = SB.prototype.appendBuffer;
    const origTS = Function.prototype.toString;
    const spoof = new Map();
    const newTS = function () { if (spoof.has(this)) return spoof.get(this); return origTS.call(this); };
    spoof.set(newTS, origTS.call(origTS));
    Function.prototype.toString = newTS;
    const hooked = function (d) {
      try {
        let id = ids.get(this);
        const mark = window.__mark || 'pre';
        if (id === undefined) { id = mark + n++; ids.set(this, id); window.__log && window.__log('SB#' + id); }
        const u8 = d instanceof ArrayBuffer ? new Uint8Array(d) : new Uint8Array(d.buffer, d.byteOffset, d.byteLength);
        let s = '';
        const C = 0x8000;
        for (let i = 0; i < u8.length; i += C) s += String.fromCharCode.apply(null, u8.subarray(i, i + C));
        window.__sendChunk && window.__sendChunk(id, btoa(s));
      } catch (e) { window.__log && window.__log('caperr ' + e.message); }
      return ap.call(this, d);
    };
    spoof.set(hooked, origTS.call(ap));
    SB.prototype.appendBuffer = hooked;
  });

  await page.goto(`${BASE}/player/${seriesId}/${itemId}`, { waitUntil: 'networkidle2', timeout: 45000 }).catch((e) => console.log('goto', e.message));
  await new Promise((r) => setTimeout(r, 3000));

  // 捕获 require，直接调 createEncryptedPlayer（绕过门禁）
  const init = await page.evaluate(async (sid, iid, def) => {
    self.rspackChunkhongguo.push([['__cap_' + Date.now()], {}, function (req) { self.__req = req; }]);
    const req = self.__req, wh = req('wh');
    const r = await fetch('/api/video/protected/play-info?aid=8662', {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Xs-From-Web': '1' },
      body: JSON.stringify({ series_id: sid, item_id: iid, definition: def }),
    });
    const j = await r.json();
    if (!j.play_info) throw new Error('play-info 无返回: ' + JSON.stringify(j).slice(0, 120));
    const p = j.play_info, a = p.audio;
    let c = document.getElementById('__myp');
    if (!c) { c = document.createElement('div'); c.id = '__myp'; c.style.cssText = 'position:fixed;left:0;top:0;width:360px;height:640px;z-index:99999;background:#000'; document.body.appendChild(c); }
    const vlist = [{ main_url: p.main_url, backup_url_1: p.backup_url, init_range: p.init_range, index_range: p.index_range, codec_type: p.codec_type, vwidth: Number(p.width), vheight: Number(p.height), bitrate: Number(p.bitrate), size: Number(p.size), definition: p.definition, kid: p.kid, encrypt: true, url_expire: Number(p.expires_at) }];
    // 音频列表必须嵌在 dynamic_video 里；codec_type 用 mp4a（接口误返 h264）
    const alist = [{ main_url: a.main_url, backup_url_1: a.backup_url, init_range: a.init_range, index_range: a.index_range, codec_type: 'mp4a', bitrate: Number(a.bitrate), size: Number(a.size), kid: a.kid, encrypt: true, url_expire: Number(a.expires_at) }];
    window.__mark = 'my';
    const config = {
      el: c, url: p.main_url, vid: p.vid, codecType: 'h264', duration: p.duration,
      expiresAt: Math.min(Number(p.expires_at), Number(a.expires_at)),
      autoplay: true, muted: true, playsinline: true, volume: 0, width: 360, height: 640,
      plugins: [wh.EncryptedDashPlayer], ignores: ['__xgVodLogger', 'error'],
      DASHPlugin: {
        vid: p.vid, playInfoType: 'TOP', secretKey: p.player_access_key, useEME: false, useUnionInfoDRM: false,
        defaultFormat: 'dash', defaultDefinition: def, useMSENotOpenDegrade: false, logMaxSize: 0, duration: p.duration,
        dashOpts: { duration: p.duration, dynamic_video: { dynamic_type: 'segment_base', video_duration: p.duration, dynamic_video_list: vlist, dynamic_audio_list: alist } },
      },
    };
    const pl = wh.createEncryptedPlayer(config, '');
    self.__player = pl;
    if (pl.on) { pl.on('error', (e) => window.__log && window.__log('PLERR ' + JSON.stringify((e && e.message) || e).slice(0, 150))); }
    return { duration: p.duration, width: p.width, height: p.height };
  }, seriesId, itemId, definition);

  const dur = (init && init.duration) || 0;
  console.log(`player created: ${init.width}x${init.height} duration=${dur}`);

  // 等高清起播
  let ok = false;
  for (let k = 0; k < 16; k++) {
    await new Promise((r) => setTimeout(r, 2500));
    const v = await page.evaluate(() => { const v = document.querySelector('#__myp video'); if (v) { v.muted = true; try { v.play(); } catch (e) {} } return v ? { w: v.videoWidth, t: +v.currentTime.toFixed(1) } : null; }).catch(() => null);
    if (v && v.w >= 700 && Object.keys(counts).some((k) => k.startsWith('my'))) { ok = true; break; }
  }
  if (!ok) console.log('WARN: 高清未起播（可能门禁/网络变化），仍尝试收已解密分片');

  // 连续加速播到片尾，收全分片
  await page.evaluate(() => { const v = document.querySelector('#__myp video'); if (v) { v.muted = true; v.playbackRate = 4; v.play().catch(() => {}); } }).catch(() => {});
  for (let k = 0; k < 120; k++) {
    await new Promise((r) => setTimeout(r, 2000));
    const v = await page.evaluate(() => { const v = document.querySelector('#__myp video'); if (!v) return null; let be = 0; try { if (v.buffered.length) be = v.buffered.end(v.buffered.length - 1); } catch (e) {} if (v.paused) v.play().catch(() => {}); return { t: +v.currentTime.toFixed(1), be: +be.toFixed(1) }; }).catch(() => null);
    if (k % 5 === 0) console.log(`play${k}:`, JSON.stringify(v), 'cap=', JSON.stringify(counts));
    if (v && dur && (v.t >= dur - 2 || v.be >= dur - 2)) break;
  }
  await new Promise((r) => setTimeout(r, 3000));
  for (const fd of Object.values(files)) fs.closeSync(fd);
  await browser.close();
  console.log('捕获分片:', JSON.stringify(counts));

  // 区分音视频（只取本播放器的 my 流）
  const myFiles = Object.keys(counts).filter((k) => k.startsWith('my')).map((k) => path.join(capDir, `dec_${k}.m4s`));
  let video = null, audio = null;
  for (const f of myFiles) { const kind = trackKind(f); if (kind === 'video' && (!video || fs.statSync(f).size > fs.statSync(video).size)) video = f; if (kind === 'audio' && (!audio || fs.statSync(f).size > fs.statSync(audio).size)) audio = f; }
  if (!video) throw new Error('没抓到视频轨，抓取失败');

  const out = path.join(outDir, `hongguo_${seriesId}_${itemId}_${definition}.mp4`);
  const args = ['-hide_banner', '-y', '-i', video];
  if (audio) args.push('-i', audio);
  args.push('-c', 'copy', '-movflags', '+faststart', out);
  console.log('remux ->', out);
  execFileSync(ffmpeg, args, { stdio: 'inherit' });
  console.log(`完成: ${out} (${(fs.statSync(out).size / 1048576).toFixed(1)} MB)`);
  if (!keep) fs.rmSync(capDir, { recursive: true, force: true });
})().catch((e) => { console.error('FATAL', e && e.stack ? e.stack.slice(0, 500) : String(e)); process.exit(1); });
