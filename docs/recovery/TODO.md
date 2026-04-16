# Recovery Harness TODO

This file is the working backlog for the Docker-based validation harness.

## Completed In This Pass

- [x] Define the documentation layout under `docs/recovery/`
- [x] Define the harness requirements and lifecycle
- [x] Define the canonical source fixture strategy
- [x] Define the snapshot rewrite tool contract
- [x] Create one scenario spec file per planned scenario
- [x] Define manual-run and report expectations
- [x] Pin the baseline source-fixture dataset with exact topic, message-count, and consumer-group values
- [x] Define the canonical snapshot `manifest.json` schema and expectation-file layout
- [x] Define the snapshot rewrite-tool JSON report schema
- [x] Define deterministic checkpoint-selection and dynamic-quorum handling rules

## Current Focus

- [x] Implement `compose/source-cluster.compose.yml`
- [x] Implement `compose/recovery-cluster.compose.yml`
- [x] Implement the source-cluster data seeding flow
- [x] Implement clean-stop snapshot capture into `fixtures/snapshots/`
- [ ] Implement the snapshot rewrite tool
- [ ] Verify the source-cluster seed and validate flow against a real local Docker run
- [ ] Verify the transactional helper against local `confluent-kafka`

## Next After Foundation

- [ ] Harden consumer-group seeding if `kafka-consumer-groups --reset-offsets` cannot materialize empty-group offsets on Confluent 8.1
- [ ] Automate Scenario 01: quorum and metadata loading
- [ ] Automate Scenario 02: partition data integrity
- [ ] Automate Scenario 03: stray detection safety net
- [ ] Automate Scenario 04: consumer group offset continuity
- [ ] Automate Scenario 05: topic and broker config preservation
- [ ] Automate Scenario 06: compacted topic recovery
- [ ] Automate Scenario 07: transaction state recovery
- [ ] Automate Scenario 08: multiple log directories
- [ ] Automate Scenario 10: RF=1 steady state and replica expansion
- [ ] Automate Scenario 11: end-to-end automation dry run
- [ ] Automate Scenario 12: repeatability from the same snapshot

## Deferred To Phase 2

- [ ] Automate Scenario 09: live snapshot / crash-consistency validation
- [ ] Add larger-data profiles once the baseline harness is stable
- [ ] Add performance-oriented reporting once correctness is proven

## Reporting

- [ ] Create the first baseline report from Scenario 01
- [ ] Create a report bundle convention under `docs/recovery/reports/runs/`
- [ ] Decide whether final summary reporting stays in `docs/recovery/reports/` or is rolled into `final-recovery-plan.md`
