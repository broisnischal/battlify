---
"battlify": patch
---

Optimization: drop the unused offline Ed25519 licensing code (`License.swift`) and
the `licensetool` target now that licensing runs through Gumroad — smaller build,
fewer targets, one clear licensing path.
