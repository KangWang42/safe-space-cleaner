# Windows cleanup categories and evidence

## Category matrix

| Category | Default class | Supported action | Main impact |
| --- | --- | --- | --- |
| Current-user `%TEMP%`, age-qualified | Verified automatic | Exact planned files only | Applications recreate temporary files; locked/current files are retained |
| `Windows\Temp`, age-qualified | Verified automatic | Exact planned files only, no forced elevation | Protected and locked files are retained |
| DirectX shader cache, age-qualified | Verified automatic in Aggressive | Exact planned files only | Shaders are rebuilt and an application may be slower on first use |
| NVIDIA/other vendor shader caches | Review required | Close GPU applications; use vendor-supported controls when available | Temporary shader compilation stutter |
| Browser or IDE cache roots | Review required | Prefer the application's clear-cache interface; close the application | Slower first load; never touch profile/sign-in data |
| Crash dumps and Windows Error Reporting | Review required | Retain while diagnosing; otherwise select exact dumps or use Windows cleanup | Loses diagnostic evidence |
| pip cache | Review required | `py -m pip cache purge` | Later installs may download or rebuild packages |
| uv cache | Review required | `uv cache clean`; do not delete the directory directly | Later operations may download/rebuild; symlink link mode can couple environments to cache data |
| npm cache | Review required | `npm cache clean --force` | Later operations may download packages again |
| NuGet, Gradle, Maven, Cargo, Conda caches | Review required | Use the owning tool after reviewing local/offline artifacts | Offline builds may fail; locally installed artifacts may be unique |
| Old installers and archives | Review required, item level | Open/identify/back up, then delete exact unchanged file | May be the only copy or needed for reinstall |
| Large user files | Review required, item level | Identify ownership and backup before deletion | User content |
| Recycle Bin | Review required | Review through Windows UI | Permanent loss of recoverable deleted items |
| `Windows.old` | Protected | Windows Settings or Disk Cleanup after a rollback decision | Rollback becomes unavailable and deletion cannot be undone |
| WinSxS/component store | Protected | `DISM /Online /Cleanup-Image /AnalyzeComponentStore`; supported servicing only | Direct deletion can make Windows unbootable or unserviceable |
| Delivery Optimization cache | Protected from direct deletion | Disk Cleanup or `Delete-DeliveryOptimizationCache` where supported | Windows normally expires it automatically |
| `hiberfil.sys` | Protected | Separate `powercfg` decision | Disabling affects hibernate, hybrid sleep, and possibly fast startup |
| Pagefile, restore points, installer/update stores, virtual disks | Protected | Owning Windows/application interface only | System recovery, servicing, application, or environment loss |

## Primary sources

- [Microsoft Support: Free up drive space in Windows](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/free-up-drive-space-in-windows) describes Storage Sense, Disk Cleanup, temporary files, and the irreversible rollback consequence of deleting a previous Windows installation.
- [Microsoft Support: Manage drive space with Storage Sense](https://support.microsoft.com/en-gb/windows/manage-drive-space-with-storage-sense-654f6ada-7bfc-45e5-966b-e24aded96ad5) states that Downloads and cloud content are not managed by default, explains Recycle Bin settings, and notes that Storage Sense targets the system drive.
- [Microsoft Learn: cleanmgr](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cleanmgr) documents supported Disk Cleanup categories and its reviewable settings interface.
- [Microsoft Learn: Clean Up the WinSxS Folder](https://learn.microsoft.com/en-au/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder?view=windows-11) warns never to delete WinSxS directly and documents supported component cleanup. Do not use `/ResetBase` as a routine cleanup because existing update packages can no longer be uninstalled.
- [Microsoft Learn: How Delivery Optimization works](https://learn.microsoft.com/en-us/windows/deployment/do/delivery-optimization-workflow) documents the Delivery Optimization cache and its normal expiration policy.
- [Microsoft Learn: Delete-DeliveryOptimizationCache](https://learn.microsoft.com/en-us/powershell/module/deliveryoptimization/delete-deliveryoptimizationcache?view=windowsserver2025-ps) documents the owning PowerShell cmdlet on systems where it is available.
- [Microsoft Learn: Disable and re-enable hibernation](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/disable-and-re-enable-hibernation) explains that `hiberfil.sys` is system-managed and warns that disabling hibernation also disables hybrid sleep.
- [pip documentation: `pip cache`](https://pip.pypa.io/en/stable/cli/pip_cache/) documents `py -m pip cache purge`.
- [uv documentation: Caching](https://docs.astral.sh/uv/concepts/cache/) documents `uv cache clean`, cache locking, and the rule that direct cache-directory modification is never safe.
- [npm documentation: `npm cache`](https://docs.npmjs.com/cli/v7/commands/npm-cache/) states that reclaiming disk space is a valid reason for `npm cache clean`, which requires `--force`, and that the cache is otherwise self-healing.

## Interpretation limits

The fixed age thresholds, exact allowlist, process guards, and three-class interaction model are this skill's conservative operating policy, not claims that the cited vendors prescribe identical thresholds. If Windows, an application, or a package manager exposes a safer current interface, prefer it after verifying official documentation.
