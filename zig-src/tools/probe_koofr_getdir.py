"""复现 koofr「WebDAV GET 目录 → 405」偶发 404：
对新建目录连打 N 次 GET /dav/<mount>/<dir>/，统计状态码分布。
同时拉一个对照挂载点（jianguo，同轮全过）做阴性对照。
"""
import base64
import json
import time
import urllib.request

BASE = "http://192.168.1.1:15399"
U, P = "admin", "e2e-test-123456"
CRED = base64.b64encode(("%s:%s" % (U, P)).encode()).decode()
AUTH = {"Authorization": "Basic " + CRED}
OP = urllib.request.build_opener(urllib.request.ProxyHandler({}))

N = 15


def api(path, body):
    r = urllib.request.Request(BASE + path, method="POST",
                               data=json.dumps(body).encode(),
                               headers=dict(TOK, **{"Content-Type": "application/json"}))
    with OP.open(r, timeout=60) as resp:
        return json.loads(resp.read().decode())


def login():
    r = urllib.request.Request(BASE + "/api/auth/login", method="POST",
                               data=json.dumps({"username": U, "password": P}).encode(),
                               headers={"Content-Type": "application/json"})
    with OP.open(r, timeout=60) as resp:
        j = json.loads(resp.read().decode())
    tok = (j.get("data") or {}).get("token")
    assert tok, j
    return {"Authorization": "Bearer " + tok}


def get(path):
    r = urllib.request.Request(BASE + path, headers=AUTH)
    try:
        with OP.open(r, timeout=60) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code


def wait_visible(mount, tag, timeout=60):
    hdrs = TOK
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = urllib.request.Request(BASE + "/api/fs/list", method="POST",
                                   data=json.dumps({"path": "/" + mount, "refresh": False}).encode(),
                                   headers=dict(hdrs, **{"Content-Type": "application/json"}))
        with OP.open(r, timeout=60) as resp:
            j = json.loads(resp.read().decode())
        names = [x["name"] for x in (j.get("data") or {}).get("content", [])]
        if tag in names:
            return True
        time.sleep(2)
    return False


TOK = login()


def probe(mount):
    tag = "olz-koofr-repro-%d" % int(time.time())
    j = api("/api/fs/mkdir", {"path": "/%s/%s" % (mount, tag)})
    assert j.get("code") == 200, j
    ok = wait_visible(mount, tag)
    codes = {}
    for _ in range(N):
        st = get("/dav/%s/%s/" % (mount, tag))
        codes[st] = codes.get(st, 0) + 1
        time.sleep(0.3)
    print("/%s/%s visible=%s codes=%s" % (mount, tag, ok, codes))
    # 清理
    api("/api/fs/remove", {"dir": "/" + mount, "names": [tag]})
    return codes


probe("koofr")
probe("jianguo")  # 阴性对照