# Canlı Çeviri

iPhone'da çalan her videoyu (TikTok, YouTube, Instagram…) anlık çeviren, tüm uygulamaların üstünde duran siyah altyazı kutusu. Kişisel kullanım içindir; App Store'da yoktur.

## Nasıl çalışır

- **Ses yakalama:** iOS'un *Ekran Yayını* özelliğiyle telefonda çalan ses alınır (Dynamic Island'daki kırmızı nokta). Görüntü kaydedilmez.
- **Yazıya dökme:** Apple'ın cihaz içi ses tanıması (ücretsiz) ya da Gemini / OpenAI (bulut, dili kendisi algılar).
- **Çeviri:** Google Çeviri (ücretsiz), Apple Çeviri (cihaz içi), Gemini, ChatGPT veya Claude.
- **Kutu:** *Resim içinde Resim* penceresi; sürüklenir, büyütülür, ⏸ ile dondurulur, ✕ ile kapatılınca her şey durur.

## Yükleme

Her `main` güncellemesinde GitHub Actions uygulamayı derler ve **Releases** bölümüne `CanliCeviri.ipa` koyar.
SideStore'a kaynak olarak şu adres eklenebilir (güncellemeler otomatik görünür):

```
https://github.com/<kullanıcı-adı>/canli-ceviri/releases/latest/download/sidestore.json
```

## Gizlilik

Ses yalnızca telefon içinde (127.0.0.1) uzantıdan uygulamaya aktarılır. Bulut motorları seçilirse yalnızca o motorun şirketine gönderilir. API anahtarları sadece telefonda saklanır.
