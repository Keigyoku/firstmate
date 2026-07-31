# Provenance

Vendored third-party skill from upstream.

| Field | Value |
| --- | --- |
| Upstream repo | https://github.com/mattpocock/skills |
| Upstream path | `skills/engineering/wayfinder/` (`SKILL.md` + `agents/`) |
| Commit | `2ab9580` (2026-07-28) |
| Licence | MIT (Copyright (c) 2026 Matt Pocock) - full text below |

Frontmatter is preserved exactly from upstream, including `disable-model-invocation: true` (captain-invoked via `/wayfinder`; must never fire on its own).

## Unvendored hard dependencies

This skill is **not** self-contained in a fresh firstmate home.
It hard-depends on skills that are **not** vendored in this repo:

- `/grilling` - charting and ticket resolution
- `/domain-modeling` - charting and ticket resolution
- `/research` - research tickets (subagent)
- `/prototype` - prototype tickets

Those are typically installed at user level (e.g. under `~/.claude/skills/`) on the captain's machine.
They are intentionally **not** vendored here; scope was only `wayfinder` and `improve-codebase-architecture`.
A fresh firstmate home that invokes `/wayfinder` will fail partway through a chart if those dependencies are missing.
Documented so the gap is found in provenance, not mid-run.

## Frontmatter metadata note

Sibling firstmate skills under `.agents/skills/` carry `metadata.internal: true` in `SKILL.md` frontmatter so installers hide them from discovery.
This skill's frontmatter is deliberately **byte-identical** to upstream (including `disable-model-invocation: true`), so that key is not injected into `SKILL.md`.
The skill still lives under the internal `.agents/skills/` tier; treat it as internal for installers.

## Licence

MIT License

Copyright (c) 2026 Matt Pocock

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
