---
name: safe-space-cleaner
description: Audit and safely reclaim disk space on Windows, defaulting to C:, with verified temporary-file and pure-cache cleanup, review-required installer and large-file candidates, protected-path exclusions, interactive confirmation, and complete JSON/CSV/Markdown reports. Use when a user asks to inspect, clean, free, or explain disk space on a Windows drive; remove temporary or cache files; find old installers or large files; or produce an auditable cleanup report. Do not use for partitioning, formatting, registry cleaners, non-Windows systems, or deleting user content without item-level approval.
---

# Safe Space Cleaner

Use the two bundled PowerShell cleanup scripts as the only automatic deletion engines. Keep audit reports private because they contain local paths and software-usage information.

## Required references

Read [references/safety-policy.md](references/safety-policy.md) before every cleanup. Read [references/windows-cleanup-categories.md](references/windows-cleanup-categories.md) when classifying candidates, explaining impact, or invoking a system or package-manager cleanup command.

## Workflow

1. Confirm the target is Windows and normalize the requested drive; default to `C:`.
2. Check available free space. Run both `space-cleaner.ps1` and `managed-cache-cleaner.ps1` in audit mode before any deletion. Add `-DeepScan` to the file audit only when installer, package repository, and large-file discovery is needed. Do not install dependencies or request elevation merely to increase the result.
3. Present three distinct groups:
   - verified default plans: age-qualified files under fixed temporary roots, all files under fixed pure-cache roots whose owning application is closed, and pip/uv/npm cache cleanup through their owning commands;
   - review-required candidates: old installers, archives, large files, diagnostic artifacts, environment-coupled package caches, and pure caches whose owning application is still active;
   - protected locations: never directly delete.
4. If the user requested only an audit, stop after reporting. If the same request explicitly authorizes cleanup, execute both verified default plans using each plan's full SHA-256 token. General cleanup authorization covers these default plans but never review-required candidates.
5. Require explicit IDs or exact paths before acting on review-required candidates. Prefer the owning application's official cleanup command over direct directory deletion. Re-check active processes and impact immediately before execution.
6. Compare drive space before and after. Run `scripts/check-report.ps1` on every audit and cleanup JSON report, then inspect structured errors or warnings. Do not search arbitrary path text for words such as `warning` or `nan`; filenames can create false positives.
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

# Audit pip, uv, and npm pure caches through their owning tools
& "$skillRoot\scripts\managed-cache-cleaner.ps1" `
  -Mode Audit -Drive C -ReportDirectory .\local-reports

# Execute only the exact managed-cache plan produced above
& "$skillRoot\scripts\managed-cache-cleaner.ps1" `
  -Mode Clean -Drive C -PlanPath <managed-plan.json> `
  -ConfirmationToken <full-sha256-token> `
  -ReportDirectory .\local-reports

# Human-operated audit and confirmation prompt
& "$skillRoot\scripts\space-cleaner.ps1" `
  -Mode Interactive -Drive C -Profile Aggressive -DeepScan `
  -ReportDirectory .\local-reports

# Validate an audit or cleanup JSON without filename-text false positives
& "$skillRoot\scripts\check-report.ps1" -Path <report.json>
```

Use `Safe` for a 30-day minimum retention period for temporary files. Use `Aggressive` for the requested retention period, normally 7 days. Both profiles clear allowlisted pure caches without an age threshold and keep review candidates out of the default plans.

## Review-required actions

After item-level approval:

- Re-measure the candidate and confirm it is unchanged.
- Refuse to clear an application cache while its owning process is active. For package-manager caches, use only the verified owning command and its documented locking behavior.
- Run package-manager commands exactly as documented, including both npm content-cache and npx-cache cleanup; never hard-delete a cache root or package repository.
- Delete an old installer, archive, dump, or other user-visible file only by exact literal path, never by wildcard or recursive parent removal.
- Append the command, selected IDs, before/after sizes, exit code, output summary, and any skipped items to a new report beside the automatic cleanup report.

## Non-negotiable safeguards

- Never delete a directory recursively during automatic cleanup. Delete only exact files from a token-verified plan.
- Clear pip, uv, npm content, and npx caches only through their owning commands from a token-verified managed plan; never hard-delete their cache roots.
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

The test must prove old-file deletion, recent-file retention, immediate pure-cache deletion, changed-file retention, both plan-token guards, junction non-traversal, and all three managed-cache commands. Then run `quick_validate.py` against the skill directory.
