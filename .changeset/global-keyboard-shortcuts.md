---
"battlify": minor
---

Global keyboard shortcuts, with a full remapping UI in Settings › Shortcuts.

- **15 bindable actions**: toggle the charge limit, raise/lower it in 5% steps, pause/resume charging, cycle save mode, Low Power Mode, force discharge, Caffeine, Always Active, dim/restore the display, display off, sleep now, and open the Settings/Details/History windows.
- **Remap anything**: click a shortcut, type the new combination. Assigning a combination that's already taken moves it and tells you which action lost it. ⌫ removes a binding, ⎋ cancels, and **Reset to Defaults** restores the shipped set.
- **Defaults on ⌃⌥⌘** (⌃⌥⌘C for Caffeine, ⌃⌥⌘L for Low Power Mode, ⌃⌥⌘B for the charge limit, …). Sleep, force discharge, display-off, and the Details/History windows ship unbound so nothing disruptive is one stray keystroke away.
- **Needs no Accessibility permission.** Shortcuts are claimed through `RegisterEventHotKey`, so the window server delivers only the specific combinations Battlify registers — the app never sees anything else you type.
- A brief **on-screen HUD** confirms what fired, since toggling something invisible like Low Power Mode is otherwise indistinguishable from a shortcut that isn't working. Combinations another app already owns are flagged as "in use" in Settings rather than failing silently, and the menu tooltips now show each action's shortcut.
