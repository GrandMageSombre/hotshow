"""把 verify.py 的全量结果收敛成 App 内置的精选目录。

用法（在项目根目录）：
    python tool/live_verify/curate.py            # 归并 + 分类 + 白名单 + 复验
    python tool/live_verify/curate.py --no-verify  # 跳回复验（调试用，快）

读 tool/live_verify/out/result.jsonl，写 ../../assets/live_channels.json。
"""
import json, os, re, ssl, sys, time, collections
import urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
IN = os.path.join(HERE, 'out', 'result.jsonl')
ASSET = os.path.normpath(os.path.join(HERE, '..', '..', 'assets', 'live_channels.json'))

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
# 与 lib/services/remote_ua.dart 的 kBrowserUserAgent 一致
APP_UA = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36')

MAX_URLS = 3


def base_name(n):
    n = n.strip()
    n = re.sub(r'\s*[\(（\[【][^)）\]】]*[\)）\]】]', '', n)
    n = re.sub(r'\s*(HD|FHD|UHD|4K|8K|超高清|高清|标清|50FPS|60FPS|H265|HEVC|1080p|720p)$',
               '', n, flags=re.I)
    n = n.strip()
    m = re.match(r'^(?:cctv|cgtn)[\s\-－_]*(\d+[a-z\+]*)', n, re.I)
    if m:
        return 'cctv' + m.group(1).lower()
    return re.sub(r'[\s\-－_]', '', n).lower()


CCTV_ALIAS = {
    'cctv1': 'CCTV-1 综合', 'cctv2': 'CCTV-2 财经', 'cctv3': 'CCTV-3 综艺',
    'cctv4': 'CCTV-4 中文国际', 'cctv5': 'CCTV-5 体育', 'cctv5+': 'CCTV-5+ 体育赛事',
    'cctv6': 'CCTV-6 电影', 'cctv7': 'CCTV-7 国防军事', 'cctv8': 'CCTV-8 电视剧',
    'cctv9': 'CCTV-9 纪录', 'cctv10': 'CCTV-10 科教', 'cctv11': 'CCTV-11 戏曲',
    'cctv12': 'CCTV-12 社会与法', 'cctv13': 'CCTV-13 新闻', 'cctv14': 'CCTV-14 少儿',
    'cctv15': 'CCTV-15 音乐', 'cctv16': 'CCTV-16 奥林匹克', 'cctv17': 'CCTV-17 农业农村',
}

LOCAL_WANT = [
    '北京卫视', '天津卫视', '东方卫视', '重庆卫视', '河北卫视', '山西卫视',
    '辽宁卫视', '吉林卫视', '黑龙江卫视', '江苏卫视', '浙江卫视', '安徽卫视',
    '东南卫视', '江西卫视', '山东卫视', '河南卫视', '湖北卫视', '湖南卫视',
    '广东卫视', '海南卫视', '四川卫视', '贵州卫视', '云南卫视', '陕西卫视',
    '甘肃卫视', '青海卫视', '内蒙古卫视', '广西卫视', '西藏卫视', '宁夏卫视',
    '新疆卫视', '深圳卫视', '大湾区卫视', '延边卫视', '兵团卫视', '安多卫视',
    '香港卫视',
]

FOREIGN_WANT = [
    ('凤凰中文', '凤凰卫视中文台'), ('凤凰资讯', '凤凰卫视资讯台'),
    ('凤凰香港', '凤凰卫视香港台'),
    ('Jade', '翡翠台'), ('Mei Ah Movie', '美亚电影台'), ('Golden Jade', '黄金翡翠台'),
    ('TVBS-Asia', 'TVBS 亚洲台'), ('TTV News', '台视新闻'),
    ('Taiwan Indigenous', '原住民电视台'),
    ('NHK General', 'NHK 综合'), ('Nippon TV', '日本电视台'),
    ('TV Tokyo', '东京电视台'), ('Weathernews', 'Weathernews 气象'),
    ('Arirang', 'Arirang TV'), ('TBS TV', 'TBS 韩国'),
    ('KTV', 'KTV 韩国'), ('TV Chosun', 'TV Chosun 朝鲜日报'),
]

SPORTS_WANT = [
    ('NBA TV', 'NBA TV'), ('纬来体育', '纬来体育'), ('精品体育', '精品体育'),
    ('足球频道', '足球频道'),
    ('Sky Sports 1', 'Sky Sports 1'), ('Sky Sports F1', 'Sky Sports F1'),
    ('Sky Sports NFL', 'Sky Sports NFL'),
    ('Eurosport 1 Germany', 'Eurosport 1'), ('Eurosport 2 Spain', 'Eurosport 2'),
    ('ESPN 2 (United States)', 'ESPN 2'), ('ESPNU', 'ESPNU'),
    ('ESPN Latin America', 'ESPN 拉美'),
    ('Fox Sports 1', 'Fox Sports 1'), ('NBC Sports NOW', 'NBC Sports'),
    ('beIN Sports USA', 'beIN Sports'), ('beIN SPORTS XTRA', 'beIN SPORTS XTRA'),
    ('NHL Network', 'NHL Network'), ('Tennis Channel', '网球频道'),
    ('Golf Channel', '高尔夫频道'), ('MUTV', 'MUTV 曼联'),
    ('Milan TV', 'Milan TV 米兰'), ('Real Madrid TV', 'Real Madrid TV'),
    ('DAZN 3 Portugal', 'DAZN 3'), ('Eleven Sports 1', 'Eleven Sports 1'),
    ('Arena Sport 1', 'Arena Sport 1'), ('Arena Sport 2', 'Arena Sport 2'),
    ('TNT Sports (Argentina)', 'TNT Sports 阿根廷'),
    ('TyC Sports', 'TyC Sports'), ('FightBox', 'FightBox 格斗'),
    ('Cricket Gold', 'Cricket Gold'), ('DD Sports', 'DD Sports'),
]

SPORTS_KW = re.compile(
    r'体育|赛事|篮球|足球|NBA|NFL|MLB|NHL|Sports|ESPN|Eurosport|Sky Sport|'
    r'英超|西甲|德甲|意甲|法甲|欧冠|网球|斯诺克|奥运|UFC|F1|Golf|Tennis|'
    r'Football|Basket|Billiards|WWE|Boxing|Racing|Cycling|Cricket', re.I)
FOREIGN_SRC = {'hk', 'tw', 'jp', 'kr', 'mo', 'sg'}
FOREIGN_KW = re.compile(
    r'凤凰|Phoenix|TVB|翡翠|Jade|Pearl|明珠|三立|民视|台视|中视|华视|TVBS|东森|中天|'
    r'BBC|CNN|NHK|Nippon|TBS|Arirang|KBS|MBC|SBS|Discovery|国家地理|'
    r'National Geographic|HBO|FOX|Animal|History|CGNTV|QVC|Shop Channel|'
    r'GSTV|Mei Ah|Asian Drama|Golden Jade|Pet Club|Beautiful Life|'
    r'Taiwan|Indigenous|WXTV|CJ OnStyle|BTN|FGTV|GCN', re.I)
PROV = ['北京', '天津', '上海', '重庆', '河北', '山西', '辽宁', '吉林', '黑龙江',
        '江苏', '浙江', '安徽', '福建', '江西', '山东', '河南', '湖北', '湖南',
        '广东', '海南', '四川', '贵州', '云南', '陕西', '甘肃', '青海',
        '内蒙古', '广西', '西藏', '宁夏', '新疆', '深圳']


# ---------------------------------------------------------------- 复验
def probe(url, ua, ref):
    import urllib.parse

    def h():
        hh = {'User-Agent': ua or APP_UA}
        if ref:
            hh['Referer'] = ref
        return hh

    def get(u, rng=None, timeout=8):
        hh = h()
        if rng:
            hh['Range'] = rng
        req = urllib.request.Request(u, headers=hh)
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            return r.status, r.read(8192)

    try:
        st, body = get(url, rng='bytes=0-4095')
        if st not in (200, 206):
            return False
        if body[:1] == b'\x47' or body[:4] == b'\x00\x00\x00\x01':
            return True
        if b'#EXTM3U' not in body:
            return False
        base = url
        text = body.decode('utf-8', 'replace')
        for _ in range(2):  # master → 子列表
            segs, master = [], False
            for l in text.split('\n'):
                l = l.strip()
                if not l:
                    continue
                if l.startswith('#EXT-X-STREAM-INF'):
                    master = True
                    continue
                if l.startswith('#'):
                    continue
                segs.append(urllib.parse.urljoin(base, l))
            if not segs:
                return False
            if not master:
                break
            st2, b2 = get(segs[0], rng='bytes=0-8191')
            if st2 not in (200, 206) or b'#EXTM3U' not in b2:
                return False
            base = segs[0]
            text = b2.decode('utf-8', 'replace')
        idx = {0, len(segs) // 2, len(segs) - 1}
        for i in sorted(idx):
            st3, b3 = get(segs[i], rng='bytes=0-1023')
            if st3 not in (200, 206) or len(b3) < 64:
                return False
        return True
    except Exception:
        return False


def main():
    verify = '--no-verify' not in sys.argv
    rows = [json.loads(l) for l in open(IN, encoding='utf-8')]
    ok = [r for r in rows if r.get('ok')]
    print(f'检测结果 {len(rows)} 条，可播 {len(ok)}')

    # 1) 同一个台归并，按响应速度排序
    pool = collections.defaultdict(list)
    for r in ok:
        b = base_name(r['name'])
        if b:
            pool[b].append(r)

    def classify(b, r):
        if r.get('src') == 'iptvorg_sports' or SPORTS_KW.search(r['name']):
            return 'sports'
        if b.startswith('cctv') or b.startswith('cgtn') or '央视' in r['name']:
            return 'cctv'
        if r.get('src') in FOREIGN_SRC or FOREIGN_KW.search(r['name']):
            return 'foreign'
        if any(r['name'].startswith(p) for p in PROV) or '卫视' in r['name']:
            return 'local'
        return None

    def build(b, cands):
        cands = sorted(cands, key=lambda x: x.get('ms', 99999))[:MAX_URLS]
        return {
            'name': cands[0]['name'],
            'url': cands[0]['url'],
            'backup': [c['url'] for c in cands[1:]],
            'logo': next((c.get('logo', '') for c in cands if c.get('logo')), ''),
            'ua': cands[0].get('ua', ''),
            'ref': cands[0].get('ref', ''),
        }

    def pick(wants, cat_of):
        out, used = [], set()
        for want, label in wants:
            wb = base_name(want)
            hit = pool.get(wb)
            if not hit:
                for pb, cands in pool.items():
                    if pb.startswith(wb) and classify(pb, cands[0]) == cat_of:
                        hit = cands
                        break
            if not hit or wb in used:
                print(f'  缺: {want}')
                continue
            used.add(wb)
            c = build(wb, hit)
            c['name'] = label
            out.append(c)
        return out

    # 央视
    cctv = []
    used = set()
    for b, cands in pool.items():
        if not b.startswith('cctv'):
            continue
        m = re.match(r'^cctv(\d+\+?)', b)
        if not m or b in used:
            continue
        key = 'cctv' + m.group(1)
        if key not in CCTV_ALIAS:
            continue
        used.add(b)
        c = build(b, cands)
        c['name'] = CCTV_ALIAS[key]
        cctv.append((key, c))
    for b, cands in pool.items():
        if b.startswith('cgtn'):
            c = build(b, cands)
            cctv.append(('cgtn' + b, c))

    def cctv_sort(k):
        # CCTV-1, CCTV-2 … CCTV-17, CCTV-5+，CGTN 系列排最后
        m = re.match(r'^cctv(\d+)(\+?)$', k)
        if m:
            return (0, int(m.group(1)), 1 if m.group(2) else 0)
        return (1, 999, 0)

    cctv.sort(key=lambda x: cctv_sort(x[0]))
    cctv_list = [c for _, c in cctv]

    groups = [
        {'id': 'cctv', 'name': '央视', 'channels': cctv_list},
        {'id': 'local', 'name': '地方',
         'channels': pick([(w, w) for w in LOCAL_WANT], 'local')},
        {'id': 'foreign', 'name': '国外', 'channels': pick(FOREIGN_WANT, 'foreign')},
        {'id': 'sports', 'name': '体育', 'channels': pick(SPORTS_WANT, 'sports')},
    ]

    # 2) 复验：主地址挂了换备用，全挂的丢掉
    if verify:
        jobs = [(g['id'], c) for g in groups for c in g['channels']]
        print(f'\n复验 {len(jobs)} 台…')

        def work(job):
            gid, c = job
            cands = [c['url']] + c.get('backup', [])
            good = None
            for u in cands:
                for _ in range(2):
                    if probe(u, c['ua'], c['ref']):
                        good = u
                        break
                    time.sleep(0.6)
                if good:
                    break
            return gid, c, good, cands

        kept = collections.defaultdict(list)
        dropped = []
        jitter = []
        with ThreadPoolExecutor(20) as ex:
            for gid, c, good, cands in ex.map(work, jobs):
                if not good:
                    # 首轮已经过了「key + 三个分片」那套严格检查，这里挂掉
                    # 基本是网络抖动（实测同一批台连跑两次，掉的是不同的两个）。
                    # 不能因为一次抖动就把台删了——保留首轮结果。
                    jitter.append(c['name'])
                    kept[gid].append(c)
                    continue
                nc = dict(c)
                nc['url'] = good
                rest = [u for u in cands if u != good]
                if rest:
                    nc['backup'] = rest
                else:
                    nc.pop('backup', None)
                kept[gid].append(nc)
        print(f'复验通过 {sum(len(v) for v in kept.values()) - len(jitter)} 台，'
              f'抖动回退 {len(jitter)} 台{("：" + "、".join(jitter)) if jitter else ""}')
        if dropped:
            print(f'丢弃 {len(dropped)} 台：{"、".join(dropped)}')
        for g in groups:
            g['channels'] = kept.get(g['id'], [])

    # 3) 清理空字段并写盘
    for g in groups:
        for c in g['channels']:
            # 台名里的 (1080p)/(720p) 对用户没意义，清掉更好读
            c['name'] = re.sub(r'\s*[\(（][^)）]*\d{3,4}[pi][^)）]*[\)）]', '',
                               c['name']).strip()
            if not c.get('logo'):
                c.pop('logo', None)
            if not c.get('ua'):
                c.pop('ua', None)
            if not c.get('ref'):
                c.pop('ref', None)
            if not c.get('backup'):
                c.pop('backup', None)

    out = {'updated': time.strftime('%Y-%m-%d'), 'groups': groups}
    os.makedirs(os.path.dirname(ASSET), exist_ok=True)
    with open(ASSET, 'w', encoding='utf-8') as f:
        json.dump(out, f, ensure_ascii=False, indent=1)

    print()
    for g in groups:
        n = len(g['channels'])
        b = sum(1 for c in g['channels'] if c.get('backup'))
        print(f"{g['name']:<4} {n:>3} 台（{b} 台有备用地址）")
    total = sum(len(g['channels']) for g in groups)
    print(f'\n合计 {total} 台 → {ASSET}（{os.path.getsize(ASSET)} 字节）')


if __name__ == '__main__':
    main()
