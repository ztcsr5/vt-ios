#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""等 build-ipa 最新一次 run 跑完，拉日志并解压。"""
import ctypes, ctypes.wintypes as w, json, os, sys, time, zipfile, io
import urllib.request, urllib.error

REPO = "ztcsr5/vt-ios"
API = "https://api.github.com"
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "_run")


def cred(target):
    advapi = ctypes.windll.advapi32

    class CREDENTIAL(ctypes.Structure):
        _fields_ = [("Flags", w.DWORD), ("Type", w.DWORD), ("TargetName", w.LPWSTR),
                    ("Comment", w.LPWSTR), ("LastWritten", ctypes.c_int64),
                    ("CredentialBlobSize", w.DWORD), ("CredentialBlob", ctypes.c_void_p),
                    ("Persist", w.DWORD), ("AttributeCount", w.DWORD),
                    ("Attributes", ctypes.c_void_p), ("TargetAlias", w.LPWSTR),
                    ("UserName", w.LPWSTR)]

    p = ctypes.POINTER(CREDENTIAL)()
    if not advapi.CredReadW(target, 1, 0, ctypes.byref(p)):
        return None
    try:
        c = p.contents
        n = c.CredentialBlobSize
        if not c.CredentialBlob or not n:
            return ""
        raw = ctypes.string_at(c.CredentialBlob, n)
        return raw.decode("utf-16-le") if n >= 2 and raw[1] == 0 else raw.decode("utf-8", "replace")
    finally:
        advapi.CredFree(p)


TOKEN = cred("git:https://ztcsr5@github.com")


def req(path, method="GET", body=None, accept="application/vnd.github+json", raw=False):
    url = path if path.startswith("http") else API + path
    data = json.dumps(body).encode() if body is not None else (b"" if method == "POST" else None)
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Authorization", "Bearer " + TOKEN)
    r.add_header("Accept", accept)
    r.add_header("User-Agent", "vt-diag")
    if body is not None:
        r.add_header("Content-Type", "application/json")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # 直连，不走系统代理
    try:
        with opener.open(r, timeout=60) as resp:
            b = resp.read()
            if raw:
                return resp.status, b
            return resp.status, (json.loads(b) if b and b[:1] in b"{[" else b.decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        b = e.read()
        if raw:
            return e.code, b
        try:
            return e.code, json.loads(b)
        except Exception:
            return e.code, b.decode("utf-8", "replace")


print("=== 等 build-ipa 新 run ===")
run = None
for i in range(70):
    s, a = req(f"/repos/{REPO}/actions/runs?per_page=6")
    runs = [x for x in a.get("workflow_runs", []) if x["name"] == "build-ipa"]
    if runs:
        r0 = runs[0]
        print(f"  [{(i*8):4d}s] #{r0['run_number']} {r0['status']}/{r0['conclusion']} sha={r0['head_sha'][:7]}")
        if r0["status"] == "completed" and r0["head_sha"].startswith("5b86785"):
            run = r0
            break
        if r0["status"] == "completed" and run is None:
            run = r0  # 最新的已完成 run
    time.sleep(8)

if not run:
    print("  没等到")
    sys.exit(1)

rid = run["id"]
print(f"\n=== run {rid} #{run['run_number']} -> {run['status']}/{run['conclusion']} ===")
s, jobs = req(f"/repos/{REPO}/actions/runs/{rid}/jobs")
for j in jobs.get("jobs", []):
    print(f"  job={j['name']} {j['status']}/{j['conclusion']} runner={j.get('runner_name')}")
    for st in j.get("steps", []):
        print(f"    {st['number']:2d}. {st['name']}  -> {st['status']}/{st['conclusion']}")

print("\n=== 拉日志 ===")
s, log = req(f"/repos/{REPO}/actions/runs/{rid}/logs", raw=True)
print(f"  status={s} bytes={len(log)}")
if s == 200 and log[:2] == b"PK":
    zpath = os.path.join(OUT, "logs.zip")
    open(zpath, "wb").write(log)
    z = zipfile.ZipFile(io.BytesIO(log))
    print(f"  {len(z.namelist())} 个日志文件:")
    for n in z.namelist():
        print(f"    {n} ({z.getinfo(n).file_size} B)")
    # 打印含 "error" / "warning:" / "构建" 的行
    for n in z.namelist():
        if not n.endswith(".txt"):
            continue
        txt = z.read(n).decode("utf-8", "replace")
        entscheidend = [l for l in txt.splitlines()
                        if any(k in l for k in ("error", "Error", "错误", "warning: ", "构建",
                                                "使用构建", "BUILD", "swiftc", "xcodebuild",
                                                "VTClient.app", "ipa", "Code Sign", "No such"))]
        if entscheidend:
            print(f"\n  ---- {n} 关键行 ({len(entscheidend)}) ----")
            for l in entscheidend[-80:]:
                print("   " + l[:300])
else:
    print(f"  {log[:300]}")
