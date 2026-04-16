# Review: Implementation Plan (docs/recovery/ + compose/ + automation/ + fixtures/)

## Context

The user has drafted a full implementation plan for the Docker-based test harness that validates `final-recovery-plan.md`. The plan is spread across 16 new spec/README files:

- Core specs: `docs/recovery/{README,harness-spec,source-fixture-spec,rewrite-tool-spec,TODO}.md`
- Scenarios: `docs/recovery/scenarios/{README + 01..12}.md`
- Runbooks: `docs/recovery/manual-runbooks/{source-cluster,scenario-runs}.md`
- Reports: `docs/recovery/reports/report-template.md`
- Organization: `{compose,automation,fixtures}/README.md`

Request: review for alignment with `final-recovery-plan.md` and identify blockers before implementation begins.

## Structural alignment — strong ✅

- All 12 scenarios (01–12) match plan Section 13 by ID, purpose, and structure. Scenario 09 (live snapshots) is correctly deferred to Phase 2.
- Core design decisions propagate consistently:
  - Clean-stop snapshots only in Phase 1
  - One canonical 9-node Confluent 8.1 source cluster
  - Immutable snapshot labels (`baseline-clean-v1`)
  - Disposable scenario working dirs under `fixtures/scenario-runs/<scenario-id>/<run-id>/`
  - Original broker IDs preserved (0,1,2 from Region A)
  - Overlay config approach ("Render recovery config overlays", not hand-written)
  - `unclean.leader.election.enable=false` baseline (no scenario overrides it)
  - UNASSIGNED directory sentinel (in rewrite-tool-spec)
  - Abort-on-empty-surviving-replica (in rewrite-tool-spec, matches plan line 17 + 372-378)
  - No live-cluster access anywhere

## Blocking ambiguities — resolve before implementation 🚫

These are cross-cutting contracts that multiple files depend on but none defines authoritatively:

1. **Source manifest schema undefined.** Scenarios 02/04/05/06/07 and `scenario-runs.md` all consume manifests ("expected offsets", "committed offsets", "config expectations", "expected final per-key values", "expected committed txn count"), but no file defines manifest format, location, or required fields. Blocks automated assertions.

2. **Rewrite tool report JSON schema undefined.** `rewrite-tool-spec.md` promises a machine-readable report; scenarios need to parse it to validate success/failure and to enumerate aborted partitions. Schema must be locked down before tool impl.

3. **"Best `.checkpoint`" selection rule undefined.** Scenarios reference picking "the best `.checkpoint`", plan Phase 2 says "highest-offset", but no doc gives the exact comparator (filename offset? epoch tiebreak?). Required by automation.

4. **VotersRecord rewrite-detection heuristic unclear.** `rewrite-tool-spec.md` says rewrite "only when dynamic quorum is detected and the caller requested it" — but the detection method (check `VotersRecord` presence in snapshot vs. parse `quorum-state` `data_version` vs. rely solely on `--rewrite-voters` flag) is not specified.

5. **Baseline dataset values not pinned.** `source-fixture-spec.md` uses vague volume language ("low single-digit GBs", "thousands to low tens of thousands"); scenarios say "at least three" consumer groups, "at least one" broker override, "representative topics across 6/12/24 partition counts" without naming them. Scenario 12 (repeatability) requires exact deterministic expected values.

6. **Multi-log-dir assumption mismatch (Scenario 08).** `source-fixture-spec.md` says 2 `log.dirs` per broker from day one; `source-cluster.md` manual runbook doesn't describe multi-log-dir setup. Either the runbook needs expansion or Scenario 08 needs a dedicated fixture variant.

## Minor inconsistencies / coverage gaps ⚠️

1. **No explicit RF<3 fail-fast scenario.** Rewrite tool spec defines abort-on-empty-surviving, but all 12 scenarios use RF=3 baseline — nothing exercises the fail-fast path. Plan explicitly flags this as out-of-scope requiring fail-fast; suggest adding a "Scenario 0" or fault-injection variant.

2. **No explicit UNASSIGNED-sentinel assertion.** No scenario verifies post-rewrite that `directories[]` in the output checkpoint actually contains the UNASSIGNED sentinel, nor that brokers correctly locate partitions across `log.dirs` because of it (Scenario 08 is the closest proxy but doesn't assert the sentinel directly).

3. **Confluent/Kafka version not referenced in scenarios.** Only `compose/README.md` names Confluent 8.1.x; scenarios use generic `kafka-*.sh` tool names without pinning the image tag.

4. **`<run-id>` generation undefined.** `fixtures/README.md` uses the placeholder but doesn't specify timestamp vs UUID vs counter, nor whether concurrent runs are supported.

5. **Report location/storage unspecified.** `report-template.md` gives structure but scenarios/runbooks don't say where reports land (`docs/recovery/reports/`? `fixtures/scenario-runs/<id>/<run>/report.md`?).

6. **Scenario 03 negative-case procedure underspecified.** The "mutate rewritten snapshot → inject fault → restart → recover" loop requires a re-run of the rewrite step that the positive-case procedure doesn't cover. Needs explicit fault-injection hook defined.

7. **Snapshot rewrite tool binary/invocation not named.** Scenarios say "run the snapshot rewrite tool" without referencing a concrete path, command, or CLI contract link — cross-reference to `rewrite-tool-spec.md` would help.

8. **"Snapshot" term overload** in organization docs: directory-copy snapshot (fixtures) vs. KRaft `.checkpoint` snapshot (rewrite tool) — clarifying glossary would help.

## Recommendation

The plan is **structurally sound and 85% complete**. Before implementation, lock down the **6 blocking ambiguities** (manifest schema, report JSON schema, best-checkpoint selector, VotersRecord detection, pinned dataset values, multi-log-dir source decision). The 8 minor items can be addressed incrementally as the harness is built.

Suggested authoring order to unblock:
1. Pin baseline dataset values in `source-fixture-spec.md` (topic list, partition counts, message counts, consumer groups, config overrides)
2. Add "Manifest Schema" section to `source-fixture-spec.md` (JSON schema + required fields)
3. Add "Report Schema" section to `rewrite-tool-spec.md` (JSON schema)
4. Add "Dynamic Quorum Detection" subsection to `rewrite-tool-spec.md`
5. Add "Checkpoint Selector" rule (new short doc or appendix)
6. Decide: expand `source-cluster.md` for multi-log-dir OR add Scenario-08-specific fixture variant

After these 6 are resolved, implementation of compose files + automation scripts + rewrite tool can proceed in parallel with high confidence.
