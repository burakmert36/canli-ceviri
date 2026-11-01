"""SideStore/AltStore kaynak dosyası (sidestore.json) üretir.

Kullanım: python3 make_source.py <ipa yolu> <sürüm> <sahip/depo>
"""
import json
import os
import sys
from datetime import datetime, timezone

ipa, version, repo = sys.argv[1], sys.argv[2], sys.argv[3]
owner = repo.split("/")[0]
size = os.path.getsize(ipa)
url = f"https://github.com/{repo}/releases/download/v{version}/CanliCeviri.ipa"
icon = f"https://raw.githubusercontent.com/{repo}/main/icon.png"
date = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
desc = ("Telefonda çalan her videoyu (TikTok, YouTube, Instagram...) anlık çeviren yüzen altyazı kutusu. "
        "Google, Apple, Gemini, ChatGPT veya Claude ile çeviri.")

source = {
    "name": "Canlı Çeviri",
    "identifier": f"io.github.{owner.lower()}.canliceviri",
    "subtitle": "Kişisel anlık çeviri uygulaması",
    "iconURL": icon,
    "apps": [
        {
            "name": "Canlı Çeviri",
            "bundleIdentifier": "com.canliceviri.app",
            "developerName": owner,
            "subtitle": "Her videoya anlık altyazı çevirisi",
            "localizedDescription": desc,
            "iconURL": icon,
            "tintColor": "3B46C8",
            "version": version,
            "versionDate": date,
            "downloadURL": url,
            "size": size,
            "versions": [
                {
                    "version": version,
                    "date": date,
                    "downloadURL": url,
                    "size": size,
                    "minOSVersion": "18.0",
                }
            ],
            "appPermissions": {
                "entitlements": [],
                "privacy": {
                    "NSSpeechRecognitionUsageDescription": "Telefonda çalan videolardaki konuşmaları yazıya dökmek için."
                },
            },
        }
    ],
    "news": [],
}
print(json.dumps(source, ensure_ascii=False, indent=2))
