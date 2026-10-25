#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ubus-remote-test.py —— 从 PC 端完整验证 OpenWrt 的 ubus JSON-RPC 远程接入链路。

验证 4 件事：
  1) /ubus 端点可达（无需认证的 list）
  2) session login 能否换取 sid
  3) 带 sid 调用真实方法（system board / mu300dash / uci get）
  4) 凭据错误时是否给出规范错误（证明认证路径本身工作）

用法：
  python tools/ubus-remote-test.py --host 192.168.77.1 --user root --password-file <文件>
  密码只从文件或环境变量读，绝不写在命令行里（避免进 shell 历史）。
"""
import argparse
import json
import os
import sys
import urllib.request
import urllib.error

NULL_SID = "00000000000000000000000000000000"


def rpc(host, endpoint, body, timeout=12, proxy_off=True):
    """发一个 JSON-RPC 请求。

    proxy_off：显式禁用代理。本机存在系统代理，不禁用会把 LAN 请求
    交给代理，得到 LuCI 的 HTML 或 502，看起来像协议问题，其实是代理问题。
    """
    url = f"http://{host}{endpoint}"
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST")
    if proxy_off:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    else:
        opener = urllib.request.build_opener()
    try:
        with opener.open(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return None, f"<{type(e).__name__}: {e}>"


def call(host, endpoint, sid, obj, method, params=None):
    return rpc(host, endpoint, {
        "jsonrpc": "2.0", "id": 2, "method": "call",
        "params": [sid, obj, method, params or {}]})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.77.1")
    ap.add_argument("--endpoint", default="/ubus")
    ap.add_argument("--user", default="root")
    ap.add_argument("--password-file", default=os.environ.get("MU300_PASSWORD_FILE"))
    ap.add_argument("--password-env", default="MU300_PASSWORD")
    args = ap.parse_args()

    pw = None
    if args.password_file and os.path.isfile(args.password_file):
        with open(args.password_file, encoding="utf-8") as f:
            pw = f.read().strip()
    if not pw:
        pw = os.environ.get(args.password_env)

    out = []
    def say(s=""):
        out.append(s)
        print(s)

    say(f"### 目标 http://{args.host}{args.endpoint}")

    # --- 1. 端点可达性
    st, body = rpc(args.host, args.endpoint,
                   {"jsonrpc": "2.0", "id": 1, "method": "list", "params": {}})
    say(f"\n[1] list（免认证）-> HTTP {st}")
    ok_list = False
    try:
        d = json.loads(body)
        objs = d.get("result", [])
        ok_list = isinstance(objs, list) and len(objs) > 0
        say(f"    ubus 对象 {len(objs)} 个: {', '.join(objs[:12])}{' ...' if len(objs) > 12 else ''}")
    except Exception:
        say(f"    非 JSON 响应: {body[:160]}")

    if not pw:
        say("\n!! 没有拿到密码，跳过认证相关测试")
        return 0 if ok_list else 1

    # --- 2. 登录
    st, body = rpc(args.host, args.endpoint, {
        "jsonrpc": "2.0", "id": 1, "method": "call",
        "params": [NULL_SID, "session", "login",
                   {"username": args.user, "password": pw}]})
    say(f"\n[2] session login -> HTTP {st}")
    sid = None
    try:
        d = json.loads(body)
        res = d.get("result")
        # rpcd 成功: result = [0, {"ubus_rpc_session": "...", "acl": {...}}]
        if isinstance(res, list) and len(res) >= 2 and isinstance(res[1], dict):
            sid = res[1].get("ubus_rpc_session")
            acl = res[1].get("acl", {})
            say(f"    sid = {sid[:16]}..." if sid else f"    result = {res}")
            if acl:
                say(f"    ACL: access groups={acl.get('access', {}).get('group', {})}")
                say(f"         uci configs = {list((acl.get('uci') or {}).keys())[:8]}")
        else:
            say(f"    result = {res}   (0=成功 1=无效参数 2=方法不存在 3=找不到对象 4=权限拒绝)")
    except Exception:
        say(f"    非 JSON 响应: {body[:200]}")

    if not sid:
        say("\n!! 登录失败 —— 密码不对或 rpcd 口令无效")
        return 2

    # --- 3. 带 sid 调真实方法
    for obj, meth, params in [
        ("system", "board", None),
        ("system", "info", None),
        ("network.interface", "dump", None),
        ("mu300dash", "signal", None),
        ("uci", "get", {"config": "network", "section": "lan", "option": "ipaddr"}),
        ("iwinfo", "devices", None),
    ]:
        st, body = call(args.host, args.endpoint, sid, obj, meth, params)
        mark = "OK " if st == 200 and '"error"' not in body else "ERR"
        try:
            d = json.loads(body)
            if "error" in d:
                s = f"error {d['error'].get('code')} {d['error'].get('message')}"
            else:
                r = d.get("result")
                if isinstance(r, list) and len(r) >= 2:
                    val = r[1]
                else:
                    val = r
                s = json.dumps(val, ensure_ascii=False)
            s = s if len(s) <= 300 else s[:300] + "..."
        except Exception:
            s = body[:200]
        say(f"\n[3] {obj}.{meth} -> HTTP {st} [{mark}]\n    {s}")

    # --- 4. 备用端点
    st2, _ = rpc(args.host, "/cgi-bin/luci/admin/ubus",
                 {"jsonrpc": "2.0", "id": 1, "method": "list", "params": {}})
    say(f"\n[4] 备用端点 /cgi-bin/luci/admin/ubus -> HTTP {st2}")

    # --- 5. 安全边界：匿名（无 sid）能否调真实方法
    #     这是最该验的一条 —— 「端点能连」不等于「没登录也能用」
    say("\n[5] 匿名调用（NULL sid，应当被拒）")
    for obj, meth in [("system", "board"), ("uci", "get"), ("mu300dash", "signal")]:
        st, body = call(args.host, args.endpoint, NULL_SID, obj, meth,
                        {"config": "network"} if obj == "uci" else None)
        try:
            d = json.loads(body)
            r = d.get("result")
            if "error" in d:
                verdict = f"拒绝/错误: {d['error'].get('message')} ({d['error'].get('code')})"
            elif isinstance(r, list) and r and r[0] != 0:
                verdict = f"拒绝: rpcd status={r[0]} (4=权限拒绝)"
            else:
                verdict = f"!! 竟然成功: {json.dumps(r, ensure_ascii=False)[:120]}"
        except Exception:
            verdict = body[:120]
        say(f"    {obj}.{meth} -> HTTP {st}  {verdict}")

    # --- 6. 只读服务清单
    say("\n[6] rc/service（只读）")
    for obj, meth in [("rc", "list"), ("service", "list")]:
        st, body = call(args.host, args.endpoint, sid, obj, meth)
        try:
            r = json.loads(body).get("result", [])
            val = r[1] if isinstance(r, list) and len(r) >= 2 else r
            say(f"    {obj}.{meth} -> {json.dumps(val, ensure_ascii=False)[:240]}")
        except Exception:
            say(f"    {obj}.{meth} -> {body[:120]}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
