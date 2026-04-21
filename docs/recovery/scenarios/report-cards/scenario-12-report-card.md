# Scenario 12 Report Card

## What This Scenario Is Solving

In plain English, Scenario 12 answers this question:

if we rerun the same recovery suite from the same snapshot, do we get the same meaningful result, or are we only succeeding by luck?

This is the repeatability scenario. It is about trust in the harness output, not just one successful run.

Main technical references:

- [Scenario 12 Technical Spec](../scenario-12-repeatability.md)
- [Scenario 11 Technical Spec](../scenario-11-end-to-end-automation.md)
- [Latest Clean Run Report](../../reports/runs/2026-04-21-scenario-12-20260421T170720Z.md)

## Where This Scenario Can Fail

1. The first or second suite run can fail outright.
   In human terms, the automation surface works once or intermittently, but not reliably enough to trust.
   Harness help: it keeps both Scenario 11 suite manifests and their logs instead of collapsing both reruns into one opaque result, and it now skips the second pass if the first pass already failed.
   Technical detail: [Scenario 12 A1](../scenario-12-repeatability.md#a1-the-first-suite-rerun-completed-successfully) and [Scenario 12 A2](../scenario-12-repeatability.md#a2-the-second-suite-rerun-completed-successfully)

2. Both suite runs can pass, but the normalized bundles can still differ.
   That catches the class of problems where the harness is "green" but the recovered state drifts between runs.
   Harness help: it compares only the stable artifact surface and strips known run-specific noise before diffing.
   Technical detail: [Scenario 12 Normalized Bundle Contract](../scenario-12-repeatability.md#normalized-bundle-contract)

3. The bundle comparison can fail because the suite did not capture enough stable evidence to compare.
   That means the suite runs, but it still is not producing a trustworthy repeatability contract.
   Harness help: it makes the normalized bundle itself a first-class artifact, not an implicit side effect.
   Technical detail: [Scenario 12 A3](../scenario-12-repeatability.md#a3-both-normalized-bundles-were-generated-from-the-expected-stable-artifact-surface) and [Scenario 12 A4](../scenario-12-repeatability.md#a4-the-normalized-bundles-match-exactly)

## How The Harness Helps Recovery

- It compares reruns at the stable-result level instead of comparing noisy raw logs.
- It keeps both suite manifests, both normalized bundles, and the diff in one place.
- It makes repeatability a testable contract, not a claim based on memory or manual spot-checking.
