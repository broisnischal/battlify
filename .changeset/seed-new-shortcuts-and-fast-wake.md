---
"battlify": patch
---

**Shortcuts added by an update never reached anyone who had already launched the app.**
Saved bindings were loaded exactly as stored, so every action introduced after a user's
first launch arrived unbound — it appeared in Settings › Shortcuts with "Not set" beside it
and nothing ever shipped it. Defaults are now applied to actions this install has never
seen, tracked by id, so a shortcut you deliberately cleared stays cleared and nothing gets
re-seeded on every launch. In practice that means don't-charge (⌃⌥⌘H), brightness
(⌃⌥⌘] / ⌃⌥⌘[), battery saver (⌃⌥⌘E), rest/wake (⌃⌥⌘R) and cycle icon style (⌃⌥⌘I) turn up
bound on the next launch, and a combination already assigned to something else is left
alone.

**Resting now ends within a couple of seconds of you touching the Mac.** It was checked on
the same 60-second timer used to notice you'd gone away, so the display woke on the keypress
while Low Power Mode and the radios stayed held for up to a minute — the Mac felt throttled
after you'd come back to it. While resting, the check runs every two seconds instead, with a
four-second grace window at the start so the keystroke that began resting doesn't
immediately end it.

**Two actions sharing one shortcut are now repaired on load.** Assigning through the
recorder moves a taken combination rather than duplicating it, but bindings saved by older
builds could hold the same chord twice — and Carbon registers exactly one of them, so the
other silently never fired. The first action in the canonical order keeps the chord and the
rest are cleared: an obviously unbound action can be fixed in Settings, whereas a
bound-looking one that does nothing can't even be diagnosed.
