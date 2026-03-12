# Changelog

All notable changes to this project will be documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Changed
- `BACKLOG.md`: W-0009 (TCP transport) moved to `wont-do` — no current or planned consumer in the integration surface requires TCP; all paths use stdio or subprocess invocation.
- `BACKLOG.md`: W-0012 (MCP subcommand) notes updated — governance loop wrapper (W-0032) closes the feedback loop the MCP tool was designed to enable.
- `BACKLOG.md`: W-0013 (LSAP) notes updated — SDK is now 0.2.0 on PyPI (pre-stable), still no Go SDK; item remains `backlog`.
- `BACKLOG.md`: W-0029 notes clarified — removed ambiguous "W-0014 dependency: `make vendor`" reference; vendor directory was committed in Session 6.

### Added
- `BACKLOG.md` W-0032 (done): governance loop wrapper — `scripts/governance_loop/governance_loop.sh` orchestrates a headless Copilot CLI agent in a policy-governed workspace.
- `BACKLOG.md` W-0033 (ready): property-based policy testing using `testing/quick`.
- `BACKLOG.md` W-0034 (ready): `gov-lsp list-invariants` — machine-readable JSON inventory of all policy rules.
- `BACKLOG.md` W-0035 (backlog): invariant coverage report against Agent-Evaluation scenario files.
- `BACKLOG.md` W-0036 (ready): governance loop wrapper test coverage for fail-closed, violation surfacing, and clean-workspace paths.
- `BACKLOG.md` W-0037 (ready): `docs/writing-policies.md` policy authoring guide.


- `tests/governance_loop.bats` test 16: verifies that the `tee` pipeline in `test_headless_agent.sh` streams governance loop output to stdout AND writes to the artifact file simultaneously, and that `${PIPESTATUS[0]}` correctly captures the exit code of the piped command rather than `tee`.

### Removed
- `auto_apply_rename_fixes()` from `scripts/governance_loop/governance_loop.sh` — shell-level fix dispatch was the wrong design and would never scale. The agent now receives the full violation context (human-readable summary + raw JSON) and applies every fix itself using its own tools.

### Changed
- `## Continuous Improvement & Learning` section in `.github/copilot-instructions.md`: unified self-improvement framework with Identity as Architect, Mini-Retro mandate, Improvement Classes table, Knowledge Graphing, Proactive Maintenance, Improvement Flywheel, and "What Done Means" checklist.
- `## Chain-of-Thought Reasoning` section in `.github/copilot-instructions.md`: six reasoning steps specific to Policy-LSP covering policy correctness, LSP spec compliance, downstream client impact, protocol vs implementation issues, test coverage, and improvement implications.
- Skills, backlog, ADR, PROGRESS and CHANGELOG mandates to .github/copilot-instructions.md
- PROGRESS.md for append-only session history
- CHANGELOG.md (this file)
- docs/adr/0007-standardise-agent-instructions.md

### Changed
- `scripts/test_headless_agent.sh`: governance loop output now streams to stdout unconditionally (12-factor rule XI compliance). Replaced `> "$AGENT_LOGS" 2>&1 || AGENT_EXIT=$?` with `2>&1 | tee "$AGENT_LOGS" || AGENT_EXIT=${PIPESTATUS[0]}` so CI step logs show the full LSP interaction, agent reasoning, and JSON-RPC traces inline. Removed redundant conditional `cat "$AGENT_LOGS"` blocks that were only printed on failure.

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
