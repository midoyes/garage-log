#!/usr/bin/env python3
"""蒐集國際油價與匯率，估算「下週油價趨勢」，寫入 data/oil_price.json 的 prediction 欄位。

免費版限制（務必看清楚）：
- 中油公式用杜拜 70% + 布蘭特 30%（Platts 行情）。杜拜沒有免費可靠來源，所以這裡只用「布蘭特」當替代，
  方向通常一致，幅度不準。因此只輸出「趨勢（偏漲 / 偏跌 / 持平）」與公式指標變動百分比，不輸出預測價格。
- 中油的政策吸收（平穩措施、凍漲）無法由公式推出，實際牌價可能不調整。畫面上會註明。
- 每次執行都把當天的快照存進 data/prediction_log.json，累積幾週後用來回測，確認有沒有比「沿用本週牌價」準。

任何來源失敗都不會讓工作流程失敗（只在日誌留下說明），牌價更新不受影響。
"""
import html
import json
import re
import sys
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

TPE = timezone(timedelta(hours=8))
OIL = Path("data/oil_price.json")
MARKET = Path("data/market_history.json")
LOG = Path("data/prediction_log.json")
HEADERS = {
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                   "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"),
    "Accept": "application/json, text/csv, */*",
}


def get(url: str) -> str:
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", errors="replace")


def brief(t: str, n: int = 300) -> str:
    return re.sub(r"\s+", " ", t)[:n]


def yahoo_daily(symbol: str) -> dict:
    """Yahoo Finance 非官方圖表介面：回傳 {YYYY-MM-DD: 收盤價}。"""
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?range=1mo&interval=1d"
    j = json.loads(get(url))
    res = j["chart"]["result"][0]
    out = {}
    for ts, c in zip(res["timestamp"], res["indicators"]["quote"][0]["close"]):
        if c:
            out[datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d")] = float(c)
    return out


def cbc_fx() -> dict:
    """央行每日美元兌新臺幣（格式未驗證：容錯找 日期 + 20~40 的數字）。"""
    text = get("https://cpx.cbc.gov.tw/api/OpenData/FTDOpenData_Day")
    print("[央行匯率] 回應：", brief(text))
    out = {}
    try:
        data = json.loads(text)
    except ValueError:
        return out

    def walk(x):
        if isinstance(x, dict):
            d = next((v for k, v in x.items() if isinstance(v, str)
                      and re.fullmatch(r"\d{4}[-/]?\d{2}[-/]?\d{2}", v.strip())), None)
            fx = next((float(v) for k, v in x.items()
                       if ("USD" in k.upper() or "美" in k) and re.fullmatch(r"\d+(\.\d+)?", str(v))
                       and 20 <= float(v) <= 40), None)
            if d and fx:
                dd = re.sub(r"[/]", "-", d.strip())
                if re.fullmatch(r"\d{8}", dd):
                    dd = f"{dd[:4]}-{dd[4:6]}-{dd[6:]}"
                out[dd] = fx
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)

    walk(data)
    return out


def safe(label, fn):
    try:
        r = fn()
        print(f"[{label}] 取得 {len(r)} 筆，最新：{sorted(r)[-1] if r else '-'}")
        return r
    except Exception as e:  # noqa: BLE001
        print(f"[{label}] 失敗：{e}")
        return {}


def week_avg(series: dict, start: date, end: date):
    vals = [v for d, v in series.items() if start <= date.fromisoformat(d) <= end]
    return (sum(vals) / len(vals), len(vals)) if vals else (None, 0)


def main() -> None:
    market = json.loads(MARKET.read_text(encoding="utf-8")) if MARKET.exists() else {"brent": {}, "fx": {}}
    brent = safe("布蘭特 BZ=F", lambda: yahoo_daily("BZ=F"))
    fx = safe("央行匯率", cbc_fx)
    if not fx:
        fx = safe("匯率備援 TWD=X", lambda: yahoo_daily("TWD=X"))
    market["brent"].update(brent)
    market["fx"].update(fx)
    for k in ("brent", "fx"):  # 只留近 120 天
        market[k] = dict(sorted(market[k].items())[-120:])
    MARKET.parent.mkdir(parents=True, exist_ok=True)
    MARKET.write_text(json.dumps(market, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")

    today = datetime.now(TPE).date()
    mon = today - timedelta(days=today.weekday())
    # 週六日時，「本週」就是剛結束的這個週一到週五
    prev_mon = mon - timedelta(days=7)
    both = {d: market["brent"][d] * market["fx"][d] for d in market["brent"] if d in market["fx"]}
    cur, n_cur = week_avg(both, mon, mon + timedelta(days=4))
    prv, n_prv = week_avg(both, prev_mon, prev_mon + timedelta(days=4))

    pred = None
    if cur and prv and n_prv >= 3:
        pct = (cur / prv - 1) * 100
        trend = "flat" if abs(pct) < 0.5 else ("up" if pct > 0 else "down")
        pred = {
            "status": "estimate",
            "week_start": (mon + timedelta(days=7)).isoformat(),
            "trend": trend,
            "index_change_pct": round(pct, 2),
            "days_known": n_cur,
            "basis": "布蘭特替代杜拜（免費版），未計政策吸收",
            "updated": today.isoformat(),
        }
    print("預測：", pred)

    if OIL.exists():
        o = json.loads(OIL.read_text(encoding="utf-8"))
        o["prediction"] = pred
        OIL.write_text(json.dumps(o, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    # 快照（回測用）：每天一筆
    log = json.loads(LOG.read_text(encoding="utf-8")) if LOG.exists() else []
    if pred and not any(e.get("date") == today.isoformat() for e in log):
        log.append({"date": today.isoformat(), "week_start": pred["week_start"],
                    "trend": pred["trend"], "pct": pred["index_change_pct"], "days": n_cur})
        LOG.write_text(json.dumps(log[-400:], ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
