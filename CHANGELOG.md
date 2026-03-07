# Changelog

All notable changes to this project will be documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- `## Continuous Improvement & Learning` section in `.github/copilot-instructions.md`: unified self-improvement framework with Identity as Architect, Mini-Retro mandate, Improvement Classes table, Knowledge Graphing, Proactive Maintenance, Improvement Flywheel, and "What Done Means" checklist.
- `## Chain-of-Thought Reasoning` section in `.github/copilot-instructions.md`: six reasoning steps specific to Policy-LSP covering policy correctness, LSP spec compliance, downstream client impact, protocol vs implementation issues, test coverage, and improvement implications.
- Skills, backlog, ADR, PROGRESS and CHANGELOG mandates to .github/copilot-instructions.md
- PROGRESS.md for append-only session history
- CHANGELOG.md (this file)
- docs/adr/0007-standardise-agent-instructions.md

### Changed
- `.github/copilot-instructions.md`: replaced the old `## Mini-Retro — After Each Piece of Work` section with the unified self-improvement framework above.
- .gitmodules: removed .claude/skills entry
- .github/workflows/sync-skills.yml: removed .claude/skills sync step
- .github/workflows/copilot-setup-steps.yml: removed sync step, updated to read from .github/copilot-instructions.md
- .github/copilot-instructions.md: single source of truth, added Skills/Backlog/ADR/PROGRESS/CHANGELOG mandates
- README.md: updated repository layout, added AI agent instruction note

### Removed
- AGENTS.md
- CLAUDE.md
- .claude/ directory and .claude/skills submodule
- scripts/sync-copilot-instructions.sh
