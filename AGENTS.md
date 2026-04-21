# AGENTS

## Recovery Start Point

For recovery-harness work, start with these files in order:

1. [docs/recovery/HANDOFF.md](/Users/jinx/gits/saxo/poc-kafka-snapshot-recovery-into-less-brokers/docs/recovery/HANDOFF.md)
2. [docs/recovery/scenario-implementation-roadmap.md](/Users/jinx/gits/saxo/poc-kafka-snapshot-recovery-into-less-brokers/docs/recovery/scenario-implementation-roadmap.md)
3. [docs/recovery/scenarios/README.md](/Users/jinx/gits/saxo/poc-kafka-snapshot-recovery-into-less-brokers/docs/recovery/scenarios/README.md)
4. the specific scenario file being worked on

If the change touches shared contracts, also read:

- [docs/recovery/harness-spec.md](/Users/jinx/gits/saxo/poc-kafka-snapshot-recovery-into-less-brokers/docs/recovery/harness-spec.md)
- [docs/recovery/source-fixture-spec.md](/Users/jinx/gits/saxo/poc-kafka-snapshot-recovery-into-less-brokers/docs/recovery/source-fixture-spec.md)
- [docs/recovery/rewrite-tool-spec.md](/Users/jinx/gits/saxo/poc-kafka-snapshot-recovery-into-less-brokers/docs/recovery/rewrite-tool-spec.md)

## Recovery Workflow Rules

- Treat [docs/recovery/scenario-implementation-roadmap.md](/Users/jinx/gits/saxo/poc-kafka-snapshot-recovery-into-less-brokers/docs/recovery/scenario-implementation-roadmap.md) as the current execution order and status source. Individual scenario specs may lag behind reality.
- Before implementing any scenario, do a spec pass first. Capture or refresh the scenario's exact:
  - preconditions and dependencies
  - snapshot label or fixture profile
  - manifest inputs and expected outputs
  - automation entrypoints and scripts to add or change
  - assertions, evidence sources, and report artifacts
  - timing windows, tolerated nondeterminism, and cleanup rules
  - fault-injection and rollback steps for negative cases
- Prefer a test-first loop:
  - write the first failing test at the lowest useful layer
  - implement the smallest change that makes it pass
  - rerun tests, then container or end-to-end checks
  - only then move to the next slice
- Do not add host dependencies beyond Docker and basic shell tooling. Use repo-managed Docker images, wrappers, or Testcontainers instead.
- Keep exec sessions short-lived. Avoid accumulating idle PTYs.
- Do not trust a reused recovery workdir after a failed boot. Re-run `prepare` and `rewrite`, or rebuild the scenario run directory, before the next `up`.
- Never revert unrelated worktree changes.
