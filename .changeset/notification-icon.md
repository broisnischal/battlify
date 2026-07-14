---
"battlify": patch
---

Fix the missing app icon in notifications.

macOS Notification Center resolves the app icon through a compiled asset catalog
(`Assets.car` referenced by `CFBundleIconName`), which the bundle didn't include —
so notification banners showed a blank placeholder even though Finder and the Dock
looked fine. The build now compiles an asset catalog with `actool` (and only sets
`CFBundleIconName` when that catalog is actually present, so it never points at a
missing target). `scripts/make-icon.sh` also emits the catalog source from the SVG
master.
