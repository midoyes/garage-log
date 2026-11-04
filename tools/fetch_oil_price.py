#!/usr/bin/env python3
"""由 GitHub Actions 定時執行：抓台灣中油公開牌價，寫成 data/oil_price.json。

App 只讀這個 JSON（格式固定）；中油網站改版時只需要改這支腳本，不必重新發布 APK / EXE。
不依賴第三方套件。抓不到或解析失敗時以非 0 結束（Actions 會顯示紅燈），且不會覆蓋舊檔。
"""
import json
import sys
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

URL = ("https://vipmbr.cpc.com.tw/CPCSTN/ListPriceWebService.asmx/"
       "getCPCMainProdListPrice_Chinese")
OUT = Path("data/oil_price.json")
TPE = timezone(timedelta(hours=8))
KEEP = 52  # 保留一年的週歷史


def fetch() -> bytes:
    req = urllib.request.Request(URL, headers={"User-Agent": "garage-log-oil-price/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def key_of(name: str):
    if "98" in name:
        return "98"
    if "95" in name:
        return "95"
    if "92" in name:
        return "92"
    if "柴油" in name:
        return "diesel"
    return None


def parse(body: bytes):
    """容錯：任何含「產品名稱」子節點的元素都視為一列；價格欄位接受兩種命名。"""
    root = ET.fromstring(body)
    prices, effective = {}, None
    for row in root.iter():
        kids = {c.tag.split("}")[-1]: (c.text or "").strip() for c in row}
        name = kids.get("產品名稱")
        if not name:
            continue
        k = key_of(name)
        raw = kids.get("參考牌價_金額") or kids.get("牌價") or ""
        try:
            price = float(raw)
        except ValueError:
            continue
        if k is None or price <= 0 or k in prices:
            continue
        prices[k] = price
        effective = effective or kids.get("牌價生效時間") or None
    return prices, effective


def main() -> None:
    body = fetch()
    prices, effective = parse(body)
    if len(prices) < 3:
        print(f"::error::只解析到 {len(prices)} 種油品，來源格式可能改了。原始內容前 800 字：")
        print(body[:800].decode("utf-8", errors="replace"))
        sys.exit(1)

    now = datetime.now(TPE)
    old = json.loads(OUT.read_text(encoding="utf-8")) if OUT.exists() else {}
    history = old.get("history", [])
    entry = {"effective": effective or now.strftime("%Y-%m-%d"), "prices": prices}
    if not history or history[-1]["prices"] != prices:
        history.append(entry)
    history = history[-KEEP:]
    previous = history[-2] if len(history) >= 2 else None

    data = {
        "schema": 1,
        "updated_at": now.strftime("%Y-%m-%d"),  # 只到日，避免每次執行都產生 commit
        "source": "台灣中油 ListPriceWebService",
        "current": history[-1],
        "previous": previous,
        "history": history,
        "prediction": None,  # 尚未提供；驗證公式後才會加入
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("OK", prices, "生效:", effective)


if __name__ == "__main__":
    main()
