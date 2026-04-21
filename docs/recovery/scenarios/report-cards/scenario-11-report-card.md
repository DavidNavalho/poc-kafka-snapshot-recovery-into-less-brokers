# Scenario 11 Report Card

## What This Scenario Is Solving

In plain English, Scenario 11 answers this question:

can we run the whole clean-stop recovery validation suite with one command, instead of manually driving each scenario one at a time?

This is the first harness productization scenario. It is about operational usability of the validation system itself, not about adding new Kafka correctness rules.

Main technical references:

- [Scenario 11 Technical Spec](../scenario-11-end-to-end-automation.md)
- [Automation Surface](../../../automation/README.md)
- [Latest Clean Run Report](../../reports/runs/2026-04-21-scenario-11-20260421T163100Z.md)

## Where This Scenario Can Fail

1. The suite command can fail before it even starts the first scenario.
   In human terms, the automation surface itself is incomplete or miswired.
   Harness help: it records suite-level step logs and fails on the exact missing step.
   Technical detail: [Scenario 11 Recovery Procedure](../scenario-11-end-to-end-automation.md#recovery-procedure)

2. The suite can fail in the middle because one of the individual scenarios fails.
   This catches the case where the single-command path exists, but it does not reliably drive the already-green checks.
   Harness help: it records the derived run ID, step status, and per-scenario report path for every scenario it started.
   Technical detail: [Scenario 11 A2](../scenario-11-end-to-end-automation.md#a2-every-orchestrated-scenario-step-completed-successfully)

3. The suite can fail because a scenario passed operationally but its summary or report bundle was never written.
   That means the suite ran, but it did not leave behind a usable artifact set.
   Harness help: it verifies both the machine-readable summaries and the authored reports, not just exit codes.
   Technical detail: [Scenario 11 A3](../scenario-11-end-to-end-automation.md#a3-every-orchestrated-core-scenario-ended-in-a-passing-assert-summary) and [Scenario 11 A4](../scenario-11-end-to-end-automation.md#a4-the-suite-produced-a-complete-report-bundle-automatically)

## How The Harness Helps Recovery

- It turns the full clean-stop validation path into one supported command instead of a handwritten operator checklist.
- It keeps the existing scenario scripts as the source of truth, so the suite is orchestration, not duplicate validation logic.
- It emits one bundle that points back to every scenario run, which makes failures easier to resume and compare later.
