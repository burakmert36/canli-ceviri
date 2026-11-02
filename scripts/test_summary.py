#!/usr/bin/env python3
"""Test sonuçlarını (xcresult + günlükler) okunabilir bir özete çevirir."""
import json
import os
import re
import subprocess
import sys

SUITES = [
    ("unit", "Birim, stres ve uçtan uca testler"),
    ("ui", "Arayüz, döndürme ve maymun testleri"),
    ("tsan", "Thread Sanitizer (eşzamanlılık)"),
    ("asan", "Address Sanitizer (bellek)"),
]


def run(*args):
    try:
        return subprocess.check_output(args, stderr=subprocess.STDOUT, timeout=300).decode("utf-8", "replace")
    except Exception as e:  # noqa: BLE001
        return None


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def summary(bundle):
    out = run("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle)
    if not out:
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


def tests_tree(bundle):
    out = run("xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle)
    try:
        return json.loads(out) if out else None
    except ValueError:
        return None


def walk(node, acc):
    if isinstance(node, dict):
        if node.get("nodeType") == "Test Case":
            acc.append(node)
        for v in node.values():
            walk(v, acc)
    elif isinstance(node, list):
        for v in node:
            walk(v, acc)
    return acc


env = read("logs/env.txt")
print("=== CANLI ÇEVİRİ TEST RAPORU ===")
sim = os.environ.get("SIMNAME", "")
if sim:
    print("Cihaz: " + sim)
for line in env.splitlines():
    if line.startswith("Xcode") or line.startswith("Build version") or line.startswith("ProductVersion"):
        print(line)
print()

all_ok = True
build_log = read("logs/build.log")
if "** TEST BUILD SUCCEEDED **" not in build_log and "BUILD SUCCEEDED" not in build_log:
    all_ok = False
    print("DERLEME BAŞARISIZ:")
    for l in sorted(set(re.findall(r".*error:.*", build_log)))[:80]:
        print("  " + l.strip())
    print()

for key, title in SUITES:
    bundle = f"results/{key}.xcresult"
    log = read(f"logs/{key}.log")
    print(f"--- {title} ---")
    s = summary(bundle) if os.path.exists(bundle) else None
    if s is None:
        all_ok = False
        print("  Sonuç paketi yok (çalışmadı ya da derlenemedi).")
        errs = sorted(set(re.findall(r".*error:.*", log)))[:40]
        for l in errs:
            print("  " + l.strip())
        tail = log.strip().splitlines()[-25:]
        if tail:
            print("  Son satırlar:")
            for l in tail:
                print("    " + l)
        print()
        continue
    total = s.get("totalTestCount", 0)
    passed = s.get("passedTests", 0)
    failed = s.get("failedTests", 0)
    skipped = s.get("skippedTests", 0)
    print(f"  Sonuç: {s.get('result')}  toplam={total} geçti={passed} kaldı={failed} atlandı={skipped}")
    if failed:
        all_ok = False
    for f in s.get("testFailures", [])[:60]:
        print(f"  ✗ {f.get('testIdentifier') or f.get('testName')}: {f.get('failureText', '').strip()[:400]}")

    tree = tests_tree(bundle)
    if tree:
        cases = walk(tree, [])

        def secs(c):
            try:
                return float(c.get("durationInSeconds", 0) or 0)
            except (TypeError, ValueError):
                return 0.0

        slow = sorted(cases, key=lambda c: -secs(c))[:8]
        if slow:
            print("  En uzun süren testler:")
            for c in slow:
                print(f"    {c.get('name')}: {c.get('duration') or c.get('durationInSeconds')}")

    # Sanitizer raporları
    if key in ("tsan", "asan"):
        reports = re.findall(r"(WARNING: ThreadSanitizer: [^\n]*|ERROR: AddressSanitizer: [^\n]*|SUMMARY: (?:Thread|Address)Sanitizer: [^\n]*)", log)
        uniq = sorted(set(reports))
        if uniq:
            all_ok = False
            print(f"  Sanitizer bulguları ({len(reports)} rapor, {len(uniq)} farklı):")
            for r in uniq[:40]:
                print("    " + r)
            # İlk raporun yığın izinden uygulama satırları
            for m in re.finditer(r"(?:WARNING: ThreadSanitizer|ERROR: AddressSanitizer)[\s\S]{0,4000}?\n\n", log):
                frames = re.findall(r"#\d+ [^\n]*(?:CanliCeviri|AudioSender|Broadcast)[^\n]*", m.group(0))
                for fr in frames[:12]:
                    print("      " + fr.strip())
                print("      ---")
        else:
            print("  Sanitizer bulgusu yok.")

    # Performans ölçümleri
    perf = re.findall(r"Test Case '-\[\S+ (\S+)\]' measured \[([^\]]+)\] average: ([0-9.]+)", log)
    if perf:
        print("  Ölçümler:")
        for name, metric, avg in perf[:20]:
            print(f"    {name} — {metric}: ort. {avg}")
    crashes = re.findall(r".*(?:crashed|Crash: |Fatal error|EXC_BAD_ACCESS)[^\n]*", log)
    if crashes:
        all_ok = False
        print("  Çökme işaretleri:")
        for c in sorted(set(crashes))[:20]:
            print("    " + c.strip()[:300])
    print()

print("SONUÇ: BAŞARILI" if all_ok else "SONUÇ: SORUN VAR")
