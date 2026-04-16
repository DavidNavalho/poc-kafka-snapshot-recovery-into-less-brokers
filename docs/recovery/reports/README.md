# Reports

This directory defines how scenario results should be written up.

## Reporting Goal

Every executed scenario should leave behind a short report that answers:

- what snapshot label was used
- what scenario was run
- what commands or automation entry points were used
- which assertions passed or failed
- where the artifacts live
- what should happen next

## Planned Layout

```text
docs/recovery/reports/
  README.md
  report-template.md
  runs/
    <yyyy-mm-dd>-scenario-01-<run-id>.md
```

The authored scenario report should live under `docs/recovery/reports/runs/`. Raw scenario artifacts may remain under `fixtures/scenario-runs/<scenario-id>/<run-id>/`, and the report should link back to those artifacts rather than duplicate them.

## Minimum Artifacts Per Run

- broker logs
- metadata quorum status output
- topic describe output
- scenario-specific evidence

Use [report-template.md](./report-template.md) as the starting point.
