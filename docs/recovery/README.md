# Recovery Validation Spec

This directory is the spec-first validation package for the recovery approach described in [`final-recovery-plan.md`](../../final-recovery-plan.md).

The runbook in `final-recovery-plan.md` remains the recovery design. The files here define how we will prove that design out with Docker, Docker Compose, and a reusable synthetic source cluster.

## Phase 1 Goal

Prove feasibility with a deterministic, resource-conscious harness:

- Confluent Platform 8.1.x images
- 9-node combined `broker,controller` source cluster
- Clean-stop simulated snapshots via host directory copies
- Reusable canonical source fixture
- One scenario spec per file
- Manual run guidance plus report expectations

## Key Principles

- Build one canonical seeded 9-node source cluster and reuse it across scenarios.
- Never let scenarios mutate the canonical source fixture or immutable snapshot sets.
- Keep the harness small enough for a Mac mini that is doing other work.
- Treat the snapshot rewrite tool as a defined component with explicit inputs, outputs, and validation requirements.
- Capture enough artifacts per scenario to write a short report after each run.

## Shared Terms

- **Source snapshot set**: a copied clean-stop broker-data set stored under [`fixtures/README.md`](../../fixtures/README.md). This is the artifact scenarios copy into disposable working directories.
- **Metadata snapshot**: the KRaft `.checkpoint` file rewritten by the tool defined in [`rewrite-tool-spec.md`](./rewrite-tool-spec.md).
- **Standard clean-stop recovery flow**: the generic recovery execution path described in [`manual-runbooks/scenario-runs.md`](./manual-runbooks/scenario-runs.md), implementing the recovery phases in [`final-recovery-plan.md`](../../final-recovery-plan.md).

## Documents

- [Harness Spec](./harness-spec.md)
- [Source Fixture Spec](./source-fixture-spec.md)
- [Snapshot Rewrite Tool Spec](./rewrite-tool-spec.md)
- [Snapshot Rewrite Tool Implementation Draft](./rewrite-tool-implementation-plan.md)
- [Scenario Implementation Roadmap](./scenario-implementation-roadmap.md)
- [Handoff](./HANDOFF.md)
- [Scenario Index](./scenarios/README.md)
- [Scenario Report Cards](./scenarios/report-cards/README.md)
- [Manual Runbooks](./manual-runbooks/README.md)
- [Reports](./reports/README.md)
- [TODO Tracker](./TODO.md)

## Current Scope Boundary

Phase 1 focuses on clean-stop snapshots only. Live snapshot and crash-consistency validation stay in scope as a documented scenario, but are explicitly deferred until the clean-stop suite is working end-to-end.
