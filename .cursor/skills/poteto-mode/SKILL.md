---
name: poteto-mode
description: MenuBarHome local engineering notes and 2026-11-08 retired skill record for Cursor agents.
disable-model-invocation: true
icon: crown
color: yellow
---

# MenuBarHome engineering notes

Project-local notes read by `.cursor/agents/poteto-agent.md`. Repository rules in `AGENTS.md`, `CODING_STANDARDS.md`, and `.claude/rules/` take precedence.

## Core constraints

- Encode domain state explicitly (enum state machine, typed model, table) with validation at system boundaries (`../principle-model-the-domain/SKILL.md`, `../principle-boundary-discipline/SKILL.md`).
- Prove changes on the real artifact (`bash scripts/check.sh`, UI snapshots, or device verification); unit tests alone are not proof for a user-facing surface (`../principle-prove-it-works/SKILL.md`). Before reporting a benchmark number, follow `../benchmark-checklist/SKILL.md`.
- Parent agent owns every subagent result: review the diff, verify every cited `path:symbol` against `HEAD` before writing a handoff or review, and write your own summary; do not pass through what a subagent said.
- Reply in natural Chinese, conclusion first. Label facts, inferences, and guesses in the same sentence.
- For docs, commit messages, and PR text, read `../technical-writing/SKILL.md`. Cut AI vocabulary, filler, hedging, and abstract metaphors. Never invent a citation or a measured number.

## Retired on purpose (2026-11-08)

The pstack orchestration skills (`architect`, `arena`, `swarm`, `interrogate`, `how`, `why`, `reflect`), `setup-pstack` model routing, Paseo wrappers, and the tstack PR workflows are retired and uninstalled. Follow the `gh` delivery and PR policy in `AGENTS.md` instead. Do not reinstall them.
