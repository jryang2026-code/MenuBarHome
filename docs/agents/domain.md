# Domain Docs

Single-context repository: [`GLOSSARY.md`](../../GLOSSARY.md) and [`docs/adr/`](../adr/) live at the repo root.

- **Use canonical vocabulary**: name domain concepts in code, issues, PRs, and tests using the terms in `GLOSSARY.md`; avoid the synonyms listed under `_Avoid_`. Note genuine vocabulary gaps for `/domain-modeling` (`/mp-domain-modeling`).
- **Surface ADR conflicts explicitly**: read ADRs touching the area you change; never silently override an accepted ADR (`_Contradicts ADR-00XX (...), worth reopening because…_`).
