# Scenario 05 Report Card

## What This Scenario Is Solving

In plain English, Scenario 05 answers this recovery question:

after the cluster boots and the data is readable, did the important Kafka settings that shape retention, compaction, compression, and broker behavior survive the recovery unchanged?

This is the "did we preserve the intended operating behavior?" scenario. A cluster can boot and still be wrong if its dynamic topic and broker overrides silently disappear or change.

Main technical references:

- [Scenario 05 Technical Spec](../scenario-05-config-preservation.md)
- [Canonical Source Fixture](../../source-fixture-spec.md)
- [Latest Clean Run Report](../../reports/runs/2026-04-21-scenario-05-20260421T113800Z.md)

## Where This Scenario Can Fail

This scenario is not meant to fail in the happy path. If it fails, it should usually fail in one of the checkpoints below.

1. `prepare`, `rewrite`, or `up` can fail before any config comparison starts.
   Scenario 05 still depends on the same metadata and cluster-start path already proven in Scenario 01 and Scenario 02.
   Harness help: it keeps the same staged recovery flow, so an early failure is still tied to a specific phase.
   Technical detail: [Scenario 05 Preconditions](../scenario-05-config-preservation.md#preconditions)

2. `assert` can fail because a tuned topic lost or changed one of its dynamic overrides.
   In human terms, the cluster came back, but an intentionally tuned topic no longer has the settings it had before recovery.
   Harness help: it captures both the raw `kafka-configs` output and a normalized key-value view for each configured topic.
   Technical detail: [Scenario 05 A1](../scenario-05-config-preservation.md#a1-configured-topics-retain-exact-dynamic-overrides)

3. `assert` can fail because a topic that should have no dynamic overrides suddenly has one.
   This protects against accidental config drift introduced by recovery.
   Harness help: it checks a fixed list of zero-override topics and records their normalized config state explicitly.
   Technical detail: [Scenario 05 A2](../scenario-05-config-preservation.md#a2-zero-override-topics-remain-free-of-dynamic-overrides)

4. `assert` can fail because broker `0` lost or changed its pinned dynamic override.
   This is the broker-level equivalent of a topic-config mismatch.
   Harness help: it compares the recovered broker config view directly to the manifest-backed expected override.
   Technical detail: [Scenario 05 A3](../scenario-05-config-preservation.md#a3-broker-0-retains-the-exact-dynamic-broker-override)

5. `assert` can fail because brokers `1` or `2` gained unexpected dynamic overrides.
   In human terms, recovery may have introduced settings where there should be none.
   Harness help: it checks the surviving brokers individually instead of assuming that "no explicit failure" means "no config drift."
   Technical detail: [Scenario 05 A4](../scenario-05-config-preservation.md#a4-brokers-1-and-2-do-not-gain-dynamic-broker-overrides)

## How The Harness Helps Recovery

- It turns config preservation into explicit entity-by-entity comparisons instead of ad hoc CLI inspection.
- It keeps both the raw dumps and normalized comparison artifacts, so a mismatch can be diagnosed without rerunning the cluster immediately.
- It anchors every expectation to the snapshot manifest, which avoids arguments about whether a setting was supposed to exist in the first place.
