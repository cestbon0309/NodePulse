# README artwork

The gallery PNGs are optimized copies of real iOS Simulator captures, made after
the geolocation/localization and theme changes. Dashboard and detail views use
the app's built-in demo mode. Pairing uses a local PTY fixture and the real
protocol; terminal/files use an explicitly authorized localhost host-test probe.
No production systems or credentials appear. SAS values belong to expired,
disposable sessions and must never be used as an identity reference.

Chinese and English captures use the matching system-language launch arguments.
Grayscale appears in dark/light dashboards and the updated compact detail header.
The original full-resolution captures are in `ios/build/screens/`
(ignored build artifacts); optimized source PNGs are committed here.

Regenerate the 2400×1200 hero banners on macOS with Pillow:

```sh
python3 docs/assets/generate.py
```

The generator uses the repo icon, committed dashboard/detail/pairing PNGs and
macOS Arial fonts. Each PNG is kept below 600,000 bytes. Screens are not fabricated:
only resizing, device frames, compositing and color quantization are applied.
