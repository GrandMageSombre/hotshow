"""第二轮全量检测：完全复刻 App 里的请求头，并验证 key 与后续分片。

和第一轮的差别（都是「测着能播、用户播不了」的根因）：
1. UA 换成 App 真正发的那串（kBrowserUserAgent，Windows Chrome），
   而不是自己随便编的 Android UA；
2. 直播默认不带 Referer（App 里 isLive 时已改成这样），
   只有源自己声明了 http-referrer 才带；
3. 除了主列表，还要拉 `#EXT-X-KEY` 的密钥地址（AES-128 流拿不到 key 会黑屏）；
4. 抽首/中/末 3 个分片，只验首片会漏掉「后续分片全死」的直播流。
"""
import urllib.request, urllib.error, urllib.parse
import re, ssl, json, os, time, collections
from concurrent.futures import ThreadPoolExecutor

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

# 与 lib/services/remote_ua.dart 的 kBrowserUserAgent 保持一致
APP_UA = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36')
GH = 'https://gh-proxy.com/https://raw.githubusercontent.com/'

# 源清单要和 lib/services/iptv_service.dart 的 kIptvSources 保持一致
SOURCES = [
    ('vbskycn', GH + 'vbskycn/iptv/master/tv/iptv4.m3u'),
    ('bestfan_province', GH + 'best-fan/iptv-sources/main/cn_province.m3u8'),
    ('bestfan_all', GH + 'best-fan/iptv-sources/main/cn_all.m3u8'),
    ('bestfan_cctv', GH + 'best-fan/iptv-sources/main/cn_cctv.m3u8'),
    ('iptvorg_cn', GH + 'iptv-org/iptv/master/streams/cn.m3u'),
    ('dazui_4k', GH + 'imDazui/Tvlist-awesome-m3u-m3u8/master/m3u/'
     '1300%E4%B8%AA%E7%9B%B4%E6%92%AD%E6%BA%90%E5%85%A8%E9%83%A8%E6%9C%89%E6%95%88'
     '%E3%80%90%E5%85%A8%E9%83%A84k%E8%80%81%E7%94%B5%E8%84%91%E5%88%AB%E7%94%A8'
     '%E3%80%91.m3u8'),
    ('iptvorg_sports', 'https://iptv-org.github.io/iptv/categories/sports.m3u'),
    ('hk', 'https://iptv-org.github.io/iptv/countries/hk.m3u'),
    ('tw', 'https://iptv-org.github.io/iptv/countries/tw.m3u'),
    ('mo', 'https://iptv-org.github.io/iptv/countries/mo.m3u'),
    ('jp', 'https://iptv-org.github.io/iptv/countries/jp.m3u'),
    ('kr', 'https://iptv-org.github.io/iptv/countries/kr.m3u'),
    ('sg', 'https://iptv-org.github.io/iptv/countries/sg.m3u'),
]

# 输出到脚本同级的 out/（中间结果，不入库）
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out')
os.makedirs(OUT, exist_ok=True)


def fuc(s):
    q = False
    for i, c in enumerate(s):
        if c == '"':
            q = not q
        elif c == ',' and not q:
            return i
    return -1


def parse(txt):
    lines = [x.strip() for x in txt.split('\n')]
    res, cur = [], None
    for l in lines:
        if l.startswith('#EXTINF'):
            body = l.split(':', 1)[1]
            i = fuc(body)
            attrs = body[:i] if i > 0 else body
            name = body[i + 1:].strip() if i > 0 else ''
            g = re.search(r'group-title="([^"]*)"', attrs)
            ua = re.search(r'http-user-agent="([^"]*)"', attrs)
            rf = re.search(r'http-refer(?:rer|er)="([^"]*)"', attrs)
            cur = {'name': name, 'group': g.group(1) if g else '',
                   'ua': ua.group(1) if ua else '',
                   'ref': rf.group(1) if rf else '', 'url': ''}
        elif l.startswith('#EXTVLCOPT') and cur is not None:
            opt = l.split(':', 1)[-1]
            if '=' in opt:
                k, v = opt.split('=', 1)
                k = k.strip().lower()
                if k.endswith('user-agent') and not cur['ua']:
                    cur['ua'] = v.strip()
                if 'referer' in k and not cur['ref']:
                    cur['ref'] = v.strip()
        elif l and not l.startswith('#') and cur is not None:
            cur['url'] = l
            if cur['name']:
                res.append(cur)
            cur = None
    return res


def hdrs(ch, url):
    """完全按 App 的 _headersFor 来：源声明优先，直播不补同域 Referer"""
    h = {'User-Agent': ch['ua'] or APP_UA}
    if ch['ref']:
        h['Referer'] = ch['ref']
    return h


def get(url, h, rng=None, timeout=8):
    hh = dict(h)
    if rng:
        hh['Range'] = rng
    req = urllib.request.Request(url, headers=hh)
    with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
        return r.status, r.read(8192)


def media_lines(text, base):
    segs, keys, master = [], [], False
    for l in text.split('\n'):
        l = l.strip()
        if not l:
            continue
        if l.startswith('#EXT-X-STREAM-INF'):
            master = True
            continue
        if l.startswith('#EXT-X-KEY'):
            m = re.search(r'URI="([^"]+)"', l)
            if m:
                keys.append(urllib.parse.urljoin(base, m.group(1)))
            continue
        if l.startswith('#'):
            continue
        segs.append(urllib.parse.urljoin(base, l))
    return segs, keys, master


def check_line(url, h, timeout=8):
    """返回 (ok, reason)"""
    try:
        st, body = get(url, h, rng='bytes=0-4095', timeout=timeout)
        if st not in (200, 206):
            return False, f'http{st}'
        if body[:1] == b'\x47' or body[:4] == b'\x00\x00\x00\x01':
            return True, 'ts'
        if b'#EXTM3U' not in body:
            return False, 'not-m3u'
        text = body.decode('utf-8', 'replace')
        segs, keys, master = media_lines(text, url)

        # AES-128 之类的密钥地址也要拉得到，否则播到一半黑屏
        for k in keys[:2]:
            try:
                ks, kb = get(k, h, timeout=timeout)
                if ks not in (200, 206) or len(kb) < 8:
                    return False, f'key{ks}'
            except Exception:
                return False, 'key-fail'

        if not segs:
            return False, 'empty'
        if master:
            # master：分片其实是子列表，下一层再验
            st2, b2 = get(segs[0], h, rng='bytes=0-8191', timeout=timeout)
            if st2 not in (200, 206) or b'#EXTM3U' not in b2:
                return False, f'sub{st2}'
            sub, keys2, _ = media_lines(b2.decode('utf-8', 'replace'), segs[0])
            for k in keys2[:2]:
                try:
                    ks, kb = get(k, h, timeout=timeout)
                    if ks not in (200, 206) or len(kb) < 8:
                        return False, f'key{ks}'
                except Exception:
                    return False, 'key-fail'
            segs = sub
            if not segs:
                return False, 'sub-empty'

        # 抽首/中/末三个分片
        idx = {0, len(segs) // 2, len(segs) - 1}
        for i in sorted(idx):
            st3, b3 = get(segs[i], h, rng='bytes=0-1023', timeout=timeout)
            if st3 not in (200, 206) or len(b3) < 64:
                return False, f'seg{i}{st3}'
        return True, 'm3u8'
    except urllib.error.HTTPError as e:
        return False, f'http{e.code}'
    except Exception as e:
        return False, type(e).__name__


def check(job):
    src, ch = job
    url = ch['url']
    if not re.match(r'^https?://', url, re.I):
        return dict(src=src, ok=False, reason='protocol', **ch)
    h = hdrs(ch, url)
    t0 = time.time()
    # 单次失败重试一次，避免把网络抖动判成死链
    ok, reason = check_line(url, h)
    if not ok:
        time.sleep(0.8)
        ok, reason = check_line(url, h, timeout=10)
    return dict(src=src, ok=ok, reason=reason,
                ms=int((time.time() - t0) * 1000), **ch)


def main():
    jobs = []
    for sid, url in SOURCES:
        items = None
        for attempt in range(3):
            try:
                req = urllib.request.Request(url, headers={'User-Agent': APP_UA})
                with urllib.request.urlopen(req, timeout=30) as r:
                    items = parse(r.read().decode('utf-8', 'replace'))
                break
            except Exception as e:
                if attempt == 2:
                    print(f'{sid:<18} FETCH FAIL {type(e).__name__}', flush=True)
                time.sleep(1.5)
        if items is None:
            continue
        print(f'{sid:<18} {len(items):>5} 条', flush=True)
        for c in items:
            jobs.append((sid, c))

    seen, uniq = set(), []
    for j in jobs:
        k = j[1]['name'] + '|' + j[1]['url']
        if k in seen:
            continue
        seen.add(k)
        uniq.append(j)
    print(f'\n总计 {len(jobs)}，去重后 {len(uniq)}，开始检测\n', flush=True)

    out = open(f'{OUT}/result.jsonl', 'w', encoding='utf-8')
    stats = collections.Counter()
    done = 0
    with ThreadPoolExecutor(30) as ex:
        for r in ex.map(check, uniq):
            out.write(json.dumps(r, ensure_ascii=False) + '\n')
            done += 1
            stats[(r['src'], r['ok'])] += 1
            if done % 150 == 0:
                okc = sum(v for (s, ok), v in stats.items() if ok)
                print(f'  {done}/{len(uniq)} 可播 {okc}', flush=True)
                out.flush()
    out.close()
    okc = sum(v for (s, ok), v in stats.items() if ok)
    print(f'\n完成：{done} 检测，{okc} 可播（{okc*100//max(1,done)}%）', flush=True)
    by = collections.defaultdict(lambda: [0, 0])
    for (s, ok), v in stats.items():
        by[s][0] += v
        if ok:
            by[s][1] += v
    for s, _ in SOURCES:
        if s in by:
            t, o = by[s]
            print(f'  {s:<18} {o:>4}/{t:<5} {o*100//t}%', flush=True)


if __name__ == '__main__':
    main()
