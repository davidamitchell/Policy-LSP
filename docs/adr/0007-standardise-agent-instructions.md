# 0007 — Standardise agent instruction files

Date: 2026-03-07
Status: accepted

## Context

Agent instructions existed in both AGENTS.md and .github/copilot-instructions.md, kept in sync by scripts/sync-copilot-instructions.sh and a copilot-setup-steps.yml step. CLAUDE.md and .claude/ existed for Claude-specific configuration.

## Decision

Make .github/copilot-instructions.md the sole source of truth. Delete AGENTS.md, CLAUDE.md, .claude/, and scripts/sync-copilot-instructions.sh. Remove the sync step from copilot-setup-steps.yml. Update the "Read agent instructions" step to read from .github/copilot-instructions.md directly.

## Consequences

- Single source of truth for all agent instructions
- No sync scripts needed
- Consistent with all other repos in the organisation
