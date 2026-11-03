<div align="center">

# Mac Duo

**Close your MacBook lid and watch the screen tilt back, blur, and fade — an iPhone-Duo-style depth effect for the Mac.**

[العربية](#بالعربية) · English

</div>

As the lid closes past a chosen angle, Mac Duo lays a GPU-rendered copy of your screen over the built-in display and leans it away from you in true perspective, blurring and dimming the far edge more and more. Open the lid again and it eases back to flat and disappears. Clicks always pass through to your apps.

## Features

- **Lid angle sensor** — reads the MacBook hinge sensor directly over HID (no permission needed).
- **Metal rendering** — one full-screen pass: inverse homography for perspective, a Gaussian mip pyramid for height-dependent blur, and smooth dimming.
- **Live picture** — ScreenCaptureKit streams the screen in real time while the effect runs, or holds the frame from when it started.
- **Smart trigger** — starts only when the lid is really being closed, predicts fast closes, releases with hysteresis, an "opened back" dwell, or an optional timeout.
- **Spring smoothing** — the sensor's ~10 Hz steps are eased at the display refresh rate.
- **Menu bar panel** — start angle, full-effect span, blur, blur spread, dimming, dimming spread, lean back, perspective strength, live/frozen picture, timeout, preview button, angle in menu bar, launch at login, reset.
- **Languages** — English, العربية (with right-to-left layout), 简体中文.

## Requirements

- macOS 14 or later
- A MacBook with a lid angle sensor (most 2019+ models; run `build/lidprobe` to check)
- **Screen Recording** permission (System Settings → Privacy & Security → Screen & System Audio Recording)

## Build

Requires Xcode / Swift 6.

```sh
./build.sh          # builds "build/Mac Duo.app" (ad-hoc signed)
./build.sh --run    # build and launch
swift test          # run the logic tests
```

With ad-hoc signing macOS forgets the Screen Recording permission after every rebuild. Sign with your own certificate to keep it:

```sh
SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" ./build.sh --run
```

To check the renderer without Screen Recording access, launch with a test pattern and trigger the preview:

```sh
open --env MACDUO_TEST_PATTERN=1 "build/Mac Duo.app"
swift scripts/preview.swift
```

## Project layout

| Path | What |
| --- | --- |
| `Sources/LidSensorKit` | HID lid angle sensor |
| `Sources/DuoCore` | Pure logic: trigger policy, spring, perspective projection (unit tested) |
| `Sources/MacDuo` | The app: engine, screen capture, Metal renderer, overlay, menu bar panel |
| `Sources/lidprobe` | Command-line sensor probe |

## Limitations

- The effect stops when macOS sleeps as the lid shuts.
- Only the built-in display is affected.

---

## بالعربية

**Mac Duo** يضيف تأثير العمق إلى جهاز MacBook: عندما تبدأ بإغلاق الغطاء يميل محتوى الشاشة للخلف بمنظور حقيقي، ويزداد التمويه والتعتيم تدريجياً كلما اقترب الغطاء من الإغلاق، ثم يعود كل شيء لطبيعته عند فتحه.

**المميزات:** قراءة زاوية الغطاء مباشرة من المستشعر، رسم بواسطة Metal على كرت الشاشة، التقاط حي للشاشة عبر ScreenCaptureKit، إعدادات كاملة من شريط القوائم، زر معاينة، ودعم العربية والإنجليزية والصينية.

**البناء:** شغّل `./build.sh --run` من مجلد المشروع، ثم امنح التطبيق إذن **تسجيل الشاشة** من إعدادات النظام ← الخصوصية والأمن.

## License

Apache License 2.0.
