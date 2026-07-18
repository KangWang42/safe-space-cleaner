# Safety policy

## Decision hierarchy

Classify every finding before proposing an action:

1. **Verified automatic**: disposable content under a fixed allowlisted root, older than the retention cutoff, and reproducible without user data loss.
2. **Review required**: content is normally reproducible but may affect diagnostics, offline work, first-run performance, authentication state, or an active application; or it is a user-visible installer, archive, or large file.
3. **Protected**: operating-system state, rollback data, user content, cloud availability, virtual disks, package environments, project dependencies, or any path whose ownership is uncertain.

When evidence is insufficient, move an item to the more restrictive class.

## Automatic deletion contract

Audit and cleanup are separate operations. Audit writes an immutable JSON plan and derives a SHA-256 confirmation token from the exact file bytes. Cleanup must reject a missing, changed, truncated, or reformatted plan.

For every planned file, cleanup must re-check:

- the category remains enabled for the selected profile;
- the current allowlisted root equals the planned root;
- the literal path remains inside that root and on the selected drive;
- the path is a file, not a directory;
- the file is not a reparse point, system file, or offline placeholder;
- length and last-write time still match the audit snapshot;
- the file still satisfies the age cutoff.

Delete with a literal file path only. Do not use wildcards and do not recursively delete parent directories. A locked, missing, changed, inaccessible, or validation-failing file is a recorded skip or failure, never a reason to weaken the guard.

## Review approval contract

General language such as "clean my drive" authorizes only the verified automatic plan. Require the user to identify review candidates by generated ID or exact path before acting.

Before executing an approved review action:

1. Restate the candidate, measured size, effect, and recovery/re-download requirement.
2. Confirm the owning application is closed or that its official cleanup tool provides safe locking.
3. Re-measure and verify the candidate has not changed materially.
4. Prefer the official application or package-manager command.
5. Record command, version if readily available, start/end time, exit code, before/after size, stdout/stderr summary, and residual files.

Apply a per-category time budget to deep read-only measurements. Mark partial measurements explicitly and treat their byte counts as lower bounds; never use an incomplete measurement to justify automatic deletion.

Never use an approval for one candidate to clear its parent, related profiles, all users, or another drive.

## Protected content

Never directly delete or mutate:

- `WinSxS`, `Windows\Installer`, `SoftwareDistribution`, `System32`, driver stores, boot files, registry hives, paging files, or restore/shadow-copy storage;
- `Windows.old` without a separate rollback decision through Windows cleanup settings;
- `hiberfil.sys` without a separate power-feature decision using `powercfg`;
- Recycle Bin contents, Downloads, Desktop, Documents, Pictures, Videos, OneDrive/cloud placeholders, or synced folders by default;
- WSL, Docker, Hyper-V, Android emulator, database, or other virtual-disk files;
- `.venv`, Conda environments, R libraries, `node_modules`, project trees, Git repositories, local Maven artifacts of uncertain origin, or package-manager persistent data;
- browser profiles, cookies, saved logins, history, extensions, bookmarks, or session data;
- any file reached through a symlink, junction, mount point, or offline placeholder.

Use supported Windows or owning-tool interfaces for system-managed content. A large size does not reduce the protection level.

## Privacy and publication

Audit and cleanup reports can reveal account names, filenames, projects, installed tools, crash history, and browsing/application patterns. Store them in a local ignored directory with user-only access where possible. Before sharing a report or screenshot, remove usernames, machine names, tokens, private filenames, notifications, and unrelated paths. Never commit live reports to a public repository.

## Failure handling

- Treat access denied as a category result, not permission to elevate automatically.
- Do not stop services or processes to force deletion.
- Do not retry a changed file using a fresh snapshot inside clean mode; require a new audit.
- Do not treat planned bytes as measured reclaimed space. Report both deleted planned bytes and actual drive free-space change because compression, sparse files, hard links, concurrent writes, and delayed filesystem accounting can differ.
- Validate structured status fields rather than matching arbitrary filename text. Scan reports for failed or unknown actions, changed/missing skips, incomplete measurements, access errors, empty required values, and unexpected roots before claiming success.
