# Vendored Cursor skills

Cursor loads each skill from `.cursor/skills/<name>/SKILL.md`. The frontmatter `name` matches that directory. This tree follows the project skill layout in the [Agent Skills](https://cursor.com/docs/skills) docs.

## Sources

Two sources remain. The vendored date is 2026-11-03; the pstack subset was localized on 2026-11-08.

- `poteto-mode` and the retained `principle-*` subset derive from pstack by Lauren Tan. The source is https://github.com/cursor/plugins/tree/main/pstack. The MIT license is `pstack-LICENSE`. The rest of pstack (orchestration, model routing, Cursor playbooks) is retired and is not refreshed.
- mattpocock skills are by Matt Pocock. The source is https://github.com/mattpocock/skills. The MIT license is `mattpocock-LICENSE`. Each directory and its frontmatter `name` start with `mp-`.
- tstack was removed on 2026-11-08; this repo follows the commit and PR policy in `AGENTS.md` instead.

The pack includes the MIT licenses for pstack and for mattpocock. Those two files sit next to the skills.

## Refresh the skills

Only the mattpocock pack is refreshed. Use a pack directory that contains `mattpocock/`.

1. Run `python3 .cursor/skills/refresh.py <pack>`.
2. Set the vendored date in this file to the day of that run.
3. Run `python3 .cursor/skills/refresh.py --check`.

The script copies each mattpocock skill with its helper files and writes `mattpocock-LICENSE`. It deletes only the directories and license files named in `vendor-manifest.json`, so the project-local pstack subset stays. Mattpocock directories and frontmatter names gain an `mp-` prefix, and Skill tool arguments and slash commands in those skills gain it too. The script leaves `.cursor/agents/` untouched. `poteto-agent` reads `.cursor/skills/poteto-mode/SKILL.md`.
