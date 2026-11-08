---
name: poteto-mode
description: MenuBarMijia engineering style for the smallest correct change, domain modeling, boundary discipline, real verification, and delegation. Read before implementation work.
disable-model-invocation: true
icon: crown
color: yellow
---

# MenuBarMijia engineering style

Read this once before coding. It is the project-local replacement for the pstack poteto-mode playbook. The Cursor-era playbooks, orchestration skills, and model routing are retired.

## Before editing

- Restate the user's goal and the smallest change that meets it. Do not wait for confirmation. If the evidence rules out the change the user asked for, show it and stop.
- Name the data shape first, then choose the structure that encodes it: state machine, typed model, registry, table, reducer. Read `../principle-model-the-domain/SKILL.md` before writing stateful or branch-heavy logic.
- Guards belong at system boundaries. Trust internal types and keep business logic pure. Read `../principle-boundary-discipline/SKILL.md` and `../principle-type-system-discipline/SKILL.md` when crossing a layer.
- Prefer deletion and the smallest diff. Read `../principle-subtract-before-you-add/SKILL.md` and `../principle-laziness-protocol/SKILL.md`.
- For a novel interaction or architecture fork, sketch two or three variants and compare before committing. For a contested design call, get a second opinion through Paseo. Do not ask the human for a fact that a run can settle.
- Split multi-step work into units that each end in a check. Verify one unit before starting the next. Read `../principle-sequence-verifiable-units/SKILL.md`.

## Verify

- Prove the change against the real artifact: run the app, the command, or the project check. Read `../principle-prove-it-works/SKILL.md`. Tests alone are not proof for a user-facing surface.
- Fix the first place the system went wrong, not the symptom. Read `../principle-fix-root-causes/SKILL.md`.
- Test observable behavior, not implementation details. Read `../principle-test-behavior-not-implementation/SKILL.md`.
- In this repo, `bash scripts/check.sh` is the gate. Use the `menubarmijia-*` verification skills for rendering, snapshots, Windows parity, and real-device checks.
- Build the script or generator when it makes the work checkable. Read `../principle-build-the-lever/SKILL.md`. Before reporting a performance number, read `../benchmark-checklist/SKILL.md`.

## Delegate

- Route bulk reads, mechanical edits, and coverage fan-out to subagents with consolidated briefs. Keep the main context for judgment. Read `../principle-guard-the-context-window/SKILL.md`.
- Proceed on reversible work. Pause only for irreversible or external actions. Read `../principle-never-block-on-the-human/SKILL.md`.
- You own every delegate's result. Review the diff and write your own summary; do not pass through what it said.

## Write

- Reply in natural Chinese, conclusion first. Label facts, inferences, and guesses in the same sentence.
- For docs, commit messages, and PR text, read `../technical-writing/SKILL.md`. Cut AI vocabulary, filler, hedging, and abstract metaphors. Never invent a citation or a measured number.
- Prefer user delight over implementation convenience. Read `../principle-experience-first/SKILL.md`.

## Repo rules win

`AGENTS.md`, `CODING_STANDARDS.md`, and the project skills override this style. Follow them for worktrees, GitLab delivery through `scripts/forge.py`, checks, snapshots, signing, and releases.

## Retired on purpose

The pstack orchestration skills (`architect`, `arena`, `swarm`, `interrogate`, `how`, `why`, `reflect`), `setup-pstack` model routing, and the tstack PR workflows are no longer installed. Use Paseo profiles for role and model routing, `paseo-committee` or `paseo-advisor` for a second opinion, and the repo's GitLab flow for delivery. Do not reinstall them.
