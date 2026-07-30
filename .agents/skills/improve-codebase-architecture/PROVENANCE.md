# Provenance

Vendored third-party skill (captain-pinned copy; **not** current upstream).

| Field | Value |
| --- | --- |
| Upstream repo | https://github.com/mattpocock/skills |
| Upstream path (historical) | `skills/engineering/improve-codebase-architecture/` (restructured upstream after pin) |
| Source of this pin | Captain's user-level copy at `~/.claude/skills/improve-codebase-architecture/` |
| Upstream commit reference | `2ab9580` (2026-07-28) |
| Pin rationale | Captain standing rule requires the four-file layout (`SKILL.md`, `LANGUAGE.md`, `INTERFACE-DESIGN.md`, `DEEPENING.md`) and the Glossary vocabulary. Current upstream dropped those companion files and the Glossary; refreshing from upstream would delete the vocabulary the standing law rests on. |

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

## Frontmatter metadata note

Sibling firstmate skills under `.agents/skills/` carry `metadata.internal: true` in `SKILL.md` frontmatter so installers hide them from discovery.
This skill's four content files are deliberately **byte-identical** to the captain's pinned copy, so that frontmatter key is not injected into `SKILL.md`.
The skill still lives under the internal `.agents/skills/` tier; treat it as internal for installers.
