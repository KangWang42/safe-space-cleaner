---
name: safe-space-cleaner
description: Audit and safely reclaim disk space on Windows, defaulting to C:, with verified temporary-file cleanup, review-required cache and large-file candidates, protected-path exclusions, interactive confirmation, and complete JSON/CSV/Markdown reports. Use when a user asks to inspect, clean, free, or explain disk space on a Windows drive; remove temporary or cache files; find old installers or large files; or produce an auditable cleanup report. Do not use for partitioning, formatting, registry cleaners, non-Windows systems, or deleting user content without item-level approval.
---

# Safe Space Cleaner

Use the bundled PowerShell script as the only automatic deletion engine. Keep audit reports private because they contain local paths and software-usage information.

## Required references

Read [references/safety-policy.md](references/safety-policy.md) before every cleanup. Read [references/windows-cleanup-categories.md](references/windows-cleanup-categories.md) when classifying candidates, explaining impact, or invoking a system or package-manager cleanup command.

## Workflow

1. Confirm the target is Windows and normalize the requested drive; default to `C:`.
2. Check available free space and run audit mode before any deletion. Use quick audit for the executable plan and add `-DeepScan` only when developer caches and large-file discovery are needed. Do not install dependencies or request elevation merely to increase the result.
3. Present three distinct groups:
   - verified automatic plan: age-qualified files under fixed temporary/cache roots;
   - review-required candidates: old installers, large files, diagnostic artifacts, browser/application caches, and developer caches;
   - protected locations: never directly delete.
4. If the user requested only an audit, stop after reporting. If the same request explicitly authorizes cleanup, execute the verified automatic plan using its full SHA-256 token. Never infer approval for review-required candidates from general cleanup authorization.
5. Require explicit IDs or exact paths before acting on review-required candidates. Prefer the owning application's official cleanup command over direct directory deletion. Re-check active processes and impact immediately before execution.
6. Compare drive space before and after. Run `scripts/check-report.ps1` on the JSON report, then inspect any structured errors or warnings. Do not search arbitrary path text for words such as `warning` or `nan`; filenames can create false positives.
7. Report what was deleted, what was skipped, measured space change, remaining review candidates, protected items, and private report paths.

## Commands

Resolve the skill directory first, then run its script.

```powershell
# Read-only audit with deep candidate discovery
& "$skillRoot\scripts\space-cleaner.ps1" `
  -Mode Audit -Drive C -Profile Aggressive -MinAgeDays 7 -DeepScan `
  -ReviewTimeoutSeconds 180 `
  -ReportDirectory .\local-reports

# Execute only the exact automatic plan produced above
& "$skillRoot\scripts\space-cleaner.ps1" `
  -Mode Clean -Drive C -PlanPath <plan.json> `
  -ConfirmationToken <full-sha256-token> `
  -ReportDirectory .\local-reports

# Human-operated audit and confirmation prompt
& "$skillRoot\scripts\space-cleaner.ps1" `
  -Mode Interactive -Drive C -Profile Aggressive -DeepScan `
  -ReportDirectory .\local-reports

# Validate an audit or cleanup JSON without filename-text false positives
& "$skillRoot\scripts\check-report.ps1" -Path <report.json>
```

Use `Safe` for a 30-day minimum retention period and no DirectX cache plan. Use `Aggressive` for the requested retention period and the DirectX shader cache. Both modes keep review candidates out of the automatic plan.

## Review-required actions

After item-level approval:

- Re-measure the candidate and confirm it is unchanged.
- Refuse to clear a cache while its owning process is active unless the official tool provides locking and the reference confirms safe concurrency.
- Run package-manager commands exactly as documented; never hard-delete the uv cache or a package repository.
- Delete an old installer, archive, dump, or other user-visible file only by exact literal path, never by wildcard or recursive parent removal.
- Append the command, selected IDs, before/after sizes, exit code, output summary, and any skipped items to a new report beside the automatic cleanup report.

## Non-negotiable safeguards

- Never delete a directory recursively during automatic cleanup. Delete only exact files from a token-verified plan.
- Never follow reparse points, junctions, symlinks, or offline placeholders.
- Skip a file if its path, root, size, timestamp, age, attributes, or drive changed after audit.
- Never directly delete Windows component, installer, update, paging, hibernation, restore, recycle-bin, cloud, virtual-disk, environment, library, project, document, download, or desktop data.
- Never stop processes, services, Windows Update, or security software to force a deletion.
- Never publish a real user's reports, paths, filenames, account names, or cache inventory.

## Validation

Run the isolated regression test after modifying the script:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test-space-cleaner.ps1
```

The test must prove old-file deletion, recent-file retention, changed-file retention, plan-token rejection, and junction non-traversal. Then run `quick_validate.py` against the skill directory.
