#!/usr/bin/env python3
"""由 GitHub Actions 定時執行：抓台灣中油公開牌價，寫成 data/oil_price.json。

App 只讀這個 JSON（格式固定）；中油網站改版時只需要改這支腳本，不必重新發布 APK / EXE。
不依賴第三方套件。抓不到或解析失敗時以非 0 結束（Actions 會顯示紅燈），且不會覆蓋舊檔。
"""
import html
import json
import re
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

URL = ("https://vipmbr.cpc.com.tw/CPCSTN/ListPriceWebService.asmx/"
       "getCPCMainProdListPrice_Chinese")
OUT = Path("data/oil_price.json")
TPE = timezone(timedelta(hours=8))
KEEP = 52  # 保留一年的週歷史


BROWSER_HEADERS = {
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                   "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"),
    "Accept": "application/json, text/xml, application/xml, text/plain, */*",
    "Accept-Language": "zh-TW,zh;q=0.9,en;q=0.8",
}
OPENDATA_BASE = "https://vipmbr.cpc.com.tw/openData"


def get(url: str) -> bytes:
    req = urllib.request.Request(url, headers=BROWSER_HEADERS)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def brief(body: bytes, n: int = 400) -> str:
    """日誌用的摘要：去掉 base64 圖片、壓成一行。"""
    t = re.sub(r"data:[a-z/]+;base64,[A-Za-z0-9+/=]+", "data:...", body.decode("utf-8", errors="replace"))
    return re.sub(r"\s+", " ", t)[:n]


def roc_date(v):
    """中油的生效日是民國 7 碼（1151102 → 2026-11-02）；其他格式原樣回傳。"""
    if v and re.fullmatch(r"\d{7}", v):
        return f"{int(v[:3]) + 1911}-{v[3:5]}-{v[5:7]}"
    return v


def from_json(text: str):
    """容錯地從任意 JSON 結構找出油品與價格：
    任何 dict 中，有字串值含 98/95/92/柴油（產品名稱），且有名稱含「價」或 price 的數字欄位（20~60）。"""
    try:
        data = json.loads(text)
    except ValueError:
        return {}, None
    prices, effective = {}, None

    def walk(x):
        nonlocal effective
        if isinstance(x, dict):
            # 優先用「產品名稱」欄位（「型別名稱：汽柴油零售」也含「柴油」，不能拿它判斷）
            name = x.get("產品名稱") if isinstance(x.get("產品名稱"), str) else None
            if name is None:
                name = next((v for k2, v in x.items()
                             if isinstance(v, str) and "型別" not in k2 and key_of(v)), None)
            if name:
                for kk, v in x.items():
                    if "價" in kk or "price" in kk.lower():
                        try:
                            val = float(v)
                        except (TypeError, ValueError):
                            continue
                        k = key_of(name)
                        if 20 <= val <= 60 and k and k not in prices:
                            prices[k] = val
                            effective = effective or roc_date(next(
                                (str(v2) for k2, v2 in x.items() if "生效" in k2 or "date" in k2.lower()), None))
                            break
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)

    walk(data)
    return prices, effective


def candidate_urls():
    """官方 openData（JSON，實測可用）優先；舊 WebService 會被防火牆擋，只當備援。"""
    return [OPENDATA_BASE + "/MainProdListPrice", URL]


def fetch_all():
    """逐一嘗試來源，回傳 (prices, effective)；每個來源都在日誌留下狀態與摘要。"""
    for u in candidate_urls():
        try:
            body = get(u)
        except Exception as e:  # noqa: BLE001
            print(f"[失敗] {u} → {e}")
            continue
        print(f"[回應] {u} → {len(body)} bytes：{brief(body)}")
        prices, eff = parse(body)
        if len(prices) < 3:
            prices, eff = from_json(body.decode("utf-8", errors="replace"))
        if len(prices) >= 3:
            print(f"[採用] {u}")
            return prices, eff
    return {}, None


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
    """用正規表示式抓「產品名稱」與其後最近的價格欄位。

    中油回傳的 XML 曾經不是合法格式（標籤不成對），所以不用 XML 解析器；
    回傳若是被跳脫過的文字（&lt;），先還原。
    """
    text = html.unescape(body.decode("utf-8", errors="replace"))
    prices, effective = {}, None
    blocks = re.split(r"<產品名稱>", text)[1:]
    for blk in blocks:
        m = re.match(r"\s*([^<]+?)\s*</產品名稱>", blk)
        if not m:
            continue
        k = key_of(m.group(1))
        pm = re.search(r"<(?:參考牌價_金額|牌價)>\s*([0-9]+(?:\.[0-9]+)?)\s*<", blk)
        if k is None or not pm or k in prices:
            continue
        price = float(pm.group(1))
        if price <= 0:
            continue
        prices[k] = price
        em = re.search(r"<牌價生效時間>\s*([^<]+?)\s*<", blk)
        effective = effective or (em.group(1) if em else None)
    return prices, effective


def main() -> None:
    prices, effective = fetch_all()
    if len(prices) < 3:
        print(f"::error::所有來源都沒有解析出油價（只有 {len(prices)} 種）。請把上面的 [回應]/[失敗] 日誌貼給作者。")
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
