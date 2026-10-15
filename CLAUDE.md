# CLAUDE.md — Resik

## 1. Project Overview

Resik is a native Windows cleanup utility that helps users analyze and reclaim disk space from Windows and developer-tool caches.

- **Application:** Resik
- **CLI command:** `resik`
- **Platform:** Windows 10 and Windows 11
- **Implementation:** Native PowerShell
- **Runtime dependencies:** Windows and PowerShell; no required Python, Node.js, or third-party runtime.
- **Distribution:** GitHub Releases and a personal Scoop bucket.
- **Development workflow:** direct commits to `main` (see section 12).

Resik prioritizes safety, transparency, predictable behavior, and user control over aggressive cleanup.

The application has two primary categories:

1. **Windows Cleanup**
2. **Developer Cleanup**

Do not turn Resik into a registry cleaner, antivirus, general system optimizer, application uninstaller, or performance-tweaking utility.

## 2. Core Engineering Principles

- Use native PowerShell and Windows capabilities.
- Prefer documented cleanup commands provided by the relevant package manager or tool.
- Separate detection, analysis, cleanup, and reporting.
- Keep modules focused, testable, and maintainable.
- Analysis must be non-destructive.
- Require explicit user intent before potentially destructive operations.
- Validate all filesystem paths before deleting anything.
- Never claim space was reclaimed without supporting measurements.
- Never invent tool commands, options, cache paths, or environment variables.
- Verify unfamiliar behavior against official documentation or actual installed-tool help.
- Handle missing tools gracefully.
- Isolate failures so one failed target does not stop unrelated targets.
- Never silently fall back from a failed native cleanup command to broad recursive deletion.
- Avoid unnecessary dependencies and abstractions.
- Preserve user data and existing repository work.

## 3. Architecture

Adapt the existing repository instead of restructuring it unnecessarily.

A reasonable initial structure is:

```
resik/
├── src/
│   └── Resik/
│       ├── Resik.ps1
│       ├── Core/
│       ├── WindowsCleanup/
│       ├── DeveloperCleanup/
│       ├── Reporting/
│       └── UI/
├── tests/
├── docs/
├── .github/
│   └── workflows/
├── README.md
├── LICENSE
└── CLAUDE.md
```

This is a guideline, not a requirement to reorganize an existing working codebase without reason.

### Current layout

- `src/Resik/Resik.ps1`: entry point. It has no param block; it dot-sources an explicit, ordered list of files and passes `$args` to `Invoke-ResikCli`. When adding a source file, add it to this list and to `tests/TestSetup.ps1`.
- `src/Resik/Core/`: `Models.ps1` (targets, results), `Arguments.ps1` (option parsing), `Selection.ps1` (`--all`/`--only`), `Analysis.ps1` (isolated, non-destructive analysis), `NativeCommand.ps1` (the shared runner from section 6), `FileSystem.ps1` (read-only path safety checks, size and free-space measurement), `Cleanup.ps1` (isolated cleanup), `Catalog.ps1` (registered targets), `Cli.ps1` (version, help, confirmation, orchestration, exit codes).
- `src/Resik/DeveloperCleanup/`: one file per tool, each with a header comment stating the commands used and the version they were verified against. `Uv.ps1` (`uv`), `Pip.ps1` (`pip`), `Poetry.ps1` (`poetry`, verified against Poetry's documentation and source only), `Npm.ps1` (`npm`), `Pnpm.ps1` (`pnpm`) and `Yarn.ps1` (`yarn`, Yarn 1 only), both verified against their documentation only, `Go.ps1` (`go-build`, `go-modules`, verified against Go's documentation only), `Composer.ps1` (`composer`, verified against Composer's documentation and source only), `Scoop.ps1` (`scoop-apps`, `scoop-cache`), `Chocolatey.ps1` (`choco`), `NuGet.ps1` (`nuget`, verified against Microsoft's documentation only, because no .NET SDK was available), `Conda.ps1` (`conda`, verified against conda's documentation and source only, because conda was not installed), `HuggingFace.ps1` (`huggingface`), `Playwright.ps1` (`playwright`), and the analysis-only `Gradle.ps1`, `Maven.ps1`, and `JetBrains.ps1`. WinGet is unsupported because it has no cache-cleaning command.
- `src/Resik/Reporting/ConsoleReport.ps1`: console summaries, returned as strings so they are testable. `Get-ResikAnalysisGroup` sorts results into Ready, ReportOnly, Skipped, Problem, and NotFound (a `Skipped` result whose message starts with `Not detected:`); the report and the picker both use it, so keep that message prefix for missing tools. Reports take `-Width` (`Get-ResikReportWidth`, 0 when output is redirected so logs keep every detail), shorten the user profile to `~` (`ConvertTo-ResikDisplayText`), and use plain words instead of internal status names.
- `tools/Build-Release.ps1`: builds the release archive. `docs/RELEASING.md`: the release and Scoop procedure.
- `src/Resik/UI/TargetPicker.ps1`: the interactive picker. State (`New-ResikPickerState`), key handling (`Invoke-ResikPickerKey`), and screen text (`Format-ResikPickerScreen`) are pure functions; only `Show-ResikTargetPicker`, `Read-ResikPickerKey`, and the small console wrappers touch the console, so tests mock those.
- `src/Resik/UI/Spinner.ps1`: the progress spinner (`Start-ResikSpinner`, `Set-ResikSpinnerMessage`, `Stop-ResikSpinner`). It draws from a separate runspace, so it keeps moving while the main thread is blocked by a native command or a size measurement. `Invoke-ResikAnalysisWithSpinner` (`Cli.ps1`) shows it during analysis with the current target's name, and `Invoke-ResikMeasuredCommand` shows it while measuring and while the clean command runs.
- `src/Resik/WindowsCleanup/`: `RecycleBin.ps1` (`recycle-bin`, `Clear-RecycleBin`, High risk and `-ExplicitOnly`; measures only `$`-prefixed items in the user's own `<drive>:\$Recycle.Bin\<SID>` folders), `ShaderCache.ps1` (`directx-shaders`, `%LOCALAPPDATA%\D3DSCache`), `ThumbnailCache.ps1` (`thumbnails`, only `thumbcache_*.db` in `%LOCALAPPDATA%\Microsoft\Windows\Explorer`), and `WindowsUpdate.ps1` (`windows-update`, `Dism.exe /Online /Cleanup-Image /StartComponentCleanup`, never `/ResetBase`). The shader and thumbnail caches have no command, so they use `Invoke-ResikMeasuredDeletion` (`Core/Cleanup.ps1`), which deletes through `Remove-ResikDirectoryContent` and reports files in use as `PartialSuccess`. `windows-update` needs administrator rights: `New-ResikWindowsUpdateTarget` gives it no `Clean` unless `Test-ResikAdministrator` is true, so it shows as report-only with the reason, and its `Clean` checks again. Tests point `Get-ResikLocalAppDataPath`, `Get-ResikRecycleBinFolder`, and `Get-ResikDismPath` at `TestDrive` and mock `Clear-ResikRecycleBin` and `Test-ResikAdministrator`.

A target is created with `New-ResikTarget` and has `Detect`, `Analyze`, and an optional `Clean` scriptblock (without `Clean` it is analysis-only). `Clean` must re-resolve and re-validate what it removes rather than trust the earlier analysis, and returns `Status`, `Details`, `MeasuredBytes`, and `FreeSpaceChangeBytes`. Register it in `Get-ResikTargetCatalog` and list it in the help text's `Targets:` section.

The uv target shows the pattern for tool-managed caches: ask the tool for its cache location, validate it with `Get-ResikPathSafetyIssue` plus a tool-specific marker (uv's `CACHEDIR.TAG`), then pass the validated path back to the tool's own clean command (`--cache-dir`), so the tool cleans exactly what was checked. Run the clean command through `Invoke-ResikMeasuredCommand` (`Core/Cleanup.ps1`), which measures the given folders and free space before and after and classifies the result. Tools that read project files from the current folder (pnpm, Yarn, Go) run with `-WorkingDirectory (Get-ResikToolWorkingDirectory)`, the user profile folder. When a command removes an amount that cannot be predicted (`pnpm store prune`), report the size in `Details` and leave `EstimatedBytes` `$null`. Measure only what the command actually removes (pip: `http`, `http-v2`, `wheels`; npm: `_cacache`). When a tool reports neither a location nor a size (Chocolatey), leave the estimate and measurements `$null` rather than guessing a path. When a tool has a JSON preview, prefer it over parsing text (`conda clean --dry-run --json`, `hf cache prune --dry-run --format json`); hf's default output changes when it thinks an AI agent runs it, so always pass `--format json`. Paths read from environment variables or configuration files go through `Expand-ResikConfiguredPath` and then `Get-ResikPathSafetyIssue`.

A target without a documented, safe cleanup command (Gradle, Maven, JetBrains) is analysis-only: it has no `Clean`, its analysis reports the size and says how to clean it by hand, and `Format-ResikSummary -Targets` leaves it out of the reclaimable total. When Resik must delete files itself, use `Remove-ResikDirectoryTree` (`Core/Deletion.ps1`), never `Remove-Item -Recurse`, which can follow junctions in Windows PowerShell 5.1. It requires a `-Scope` folder that the path must be strictly inside, removes links without entering them, and reports items it could not delete. To empty a folder but keep it, use `Remove-ResikDirectoryContent`, which applies the same rules to each matching item. `scoop-persist` uses the tree removal directly: Scoop has no command for leftover persist data, the data belongs to the user, so the target is High risk, `-ExplicitOnly` (never chosen by `--all` or "select all"), and asks about each folder through `Read-ResikConfirmation` only when its `Clean` context has `CanPrompt`; `--force` never answers those questions.

Functions take their dependencies as parameters (for example, `Invoke-ResikCli -Targets`) rather than reading global state, so tests can inject fake targets.

### Module responsibilities

- **Core:** target registration, orchestration, path validation, shared result models, and error handling.
- **WindowsCleanup:** Windows-specific cleanup targets.
- **DeveloperCleanup:** package-manager, IDE, AI/ML, and other developer-tool targets.
- **Reporting:** console summaries and optional JSON reports.
- **UI:** interactive target selection and terminal presentation.
- **Tests:** isolated tests for analysis, selection, path safety, command execution, and reporting.

Each cleanup target should expose consistent metadata and behavior:

- Stable target ID.
- Display name and category.
- Availability and detection status.
- Risk level.
- Description of what will be removed.
- Estimated reclaimable size, if measurable.
- Analysis operation.
- Cleanup operation.
- Execution result and diagnostics.

Use consistent PowerShell interfaces or conventions. Do not introduce an elaborate plugin framework without a real need.

## 4. Cleanup Categories

Implement targets incrementally. Do not implement every target in one massive change.

### 4.1 Windows Cleanup

Potential targets:

- Recycle Bin.
- Windows and user temporary files in carefully scoped locations.
- Thumbnail cache.
- DirectX shader cache.
- Other well-understood, disposable Windows caches.

Safety requirements:

- Distinguish user-owned temporary files from system-managed locations.
- Prefer supported Windows cleanup mechanisms when available.
- Do not broadly delete Windows directories.
- Skip locked or inaccessible files and report the reason.
- Do not automatically elevate privileges.
- Do not delete restore points, documents, application data, browser profiles, or arbitrary system files.
- Treat Recycle Bin cleanup as destructive and require explicit confirmation.
- Explain that cleaned caches may be regenerated.

### 4.2 Developer Cleanup

Organize targets independently so they can be added, tested, and maintained separately.

#### Python and machine learning

- uv
- pip
- Conda
- Hugging Face Hub cache
- PyTorch compilation caches, including TorchInductor
- Triton compilation cache

#### Windows package managers

- Scoop
- Chocolatey
- WinGet

#### JavaScript and browser automation

- npm
- Playwright browser installations

#### Java and .NET

- Maven
- Gradle
- NuGet and .NET caches

#### IDEs

- JetBrains IDE caches, including multiple products and versions.

Potential future targets include pnpm, Yarn, and Cargo.

Do not assume every target is safe to clean in every environment.

## 5. Preferred Cleanup Mechanism: Native Tool Commands

**For Developer Cleanup, prefer the package manager's or tool's own documented cache-cleaning commands over manually deleting cache directories.**

This is a core architectural requirement.

### Required decision order

For each target:

1. Detect whether the tool is installed.
2. Identify its executable, version, and relevant configuration where practical.
3. Verify supported cache-inspection and cleanup commands using official documentation or installed-tool help.
4. Prefer the tool's native commands for inspection and cleanup.
5. Use a documented preview or dry-run option when available.
6. If no safe native cleanup command exists, evaluate whether narrowly scoped filesystem cleanup can be implemented safely.
7. If neither approach is verifiably safe, provide analysis-only behavior or mark the target unsupported.

Never invent commands or silently fall back to broad deletion.

### 5.1 uv

Prefer:

```
uv cache dir
uv cache clean
```

Verify availability and behavior against the installed version.

Do not remove virtual environments, project files, or installed dependencies.

### 5.2 pip

Prefer:

```
python -m pip cache info
python -m pip cache purge
```

The executable and interpreter must correspond to the intended Python installation.

Account for multiple Python installations where practical. Do not remove virtual environments or installed packages.

### 5.3 Conda

Prefer documented `conda clean` operations.

Use:

```
conda clean --all --dry-run
```

only when the installed version supports the option and its documented behavior is appropriate.

Do not use `--force-pkgs-dirs` by default. Explain risks associated with package caches and shared environments.

### 5.4 Scoop

Use the following Scoop cleanup commands as separate operations:

```
scoop cleanup *
scoop cache rm *
```

- `scoop cleanup *` cleans up old versions of installed Scoop applications where supported.
- `scoop cache rm *` removes cached downloads where supported.
- Verify the installed Scoop version and command syntax before execution.
- Treat these as two distinct cleanup operations with separate results.
- Do not combine them into an opaque operation that hides partial failures.
- Do not remove installed applications.
- Make the scope and consequences clear to the user before execution.
- Use an analysis or preview mechanism only if Scoop actually supports one for the relevant operation.
- Do not execute these commands during `--dry-run`.
- Do not assume that these Scoop commands support a dry-run or preview option.

When executing native commands, capture the exit code and diagnostic output. If one command fails, report the failure and handle the other operation according to the user's selected targets and the safety policy.

### 5.5 Chocolatey

Verify supported cache-related operations against the installed version and official documentation.

Do not assume `%TEMP%` is Chocolatey's cache. Do not remove installed packages or required metadata.

### 5.6 WinGet

Do not invent a universal WinGet cache-cleaning command.

Implement only verified, supported operations. If a safe operation cannot be established, provide analysis-only behavior or mark the target unsupported.

### 5.7 npm

Prefer:

```
npm cache verify
npm cache clean --force
```

Detect the effective cache directory through npm configuration. Never delete `node_modules`, project directories, or package manifests.

### 5.8 Maven

Detect the configured local repository where practical.

Do not delete the entire `.m2/repository` by default. Use conservative, explicitly scoped cleanup.

### 5.9 Gradle

Respect the applicable configuration and cache locations.

Do not delete the entire `.gradle` directory. Restrict deletion to verified disposable caches or use analysis-only behavior.

### 5.10 NuGet and .NET

Prefer supported commands such as:

```
dotnet nuget locals all --list
```

Use the appropriate documented cache-clearing operation for selected locations.

Treat the global packages directory as a special case because it can contain packages required by existing projects. Never remove SDKs, runtimes, or project dependencies.

### 5.11 Hugging Face

- Respect `HF_HOME`, `HF_HUB_CACHE`, and the effective cache location.
- Use supported cache listing and pruning commands when available.
- Prefer pruning unused cached revisions over deleting the entire cache.
- Do not indiscriminately remove models, datasets, or user-managed artifacts.
- Verify CLI compatibility against the installed version.

### 5.12 PyTorch and Triton

Respect applicable configuration and environment variables, including:

- `TORCHINDUCTOR_CACHE_DIR`
- `TRITON_CACHE_DIR`

Only clean directories confirmed to contain disposable compilation artifacts. Do not remove model checkpoints, datasets, environments, or project files.

### 5.13 JetBrains IDEs

- Detect cache directories for multiple products and versions.
- Restrict cleanup to confirmed cache locations.
- Preserve settings, plugins, projects, and Local History.
- Explain that IDEs may need to rebuild indexes after cleanup.

### 5.14 Playwright

- Respect `PLAYWRIGHT_BROWSERS_PATH` and supported configured locations.
- Do not treat browser installations as ordinary disposable caches.
- Browser removal must be a separately selected, explicitly explained operation.
- Warn that browsers may need to be downloaded again.
- Never delete arbitrary directories merely because their names contain `playwright`.

## 6. Native Command Execution Requirements

Create a shared mechanism for running external tools safely.

It should:

- Use a known executable path or a verified executable resolved from the environment.
- Pass arguments safely without constructing executable command strings from untrusted input.
- Capture stdout, stderr, exit code, and duration where practical.
- Support appropriate timeouts.
- Distinguish command-not-found, timeout, nonzero exit code, and successful execution.
- Avoid shell injection.
- Avoid exposing secrets in logs or reports.
- Respect user cancellation where feasible.
- Report the exact operation attempted without unnecessarily dumping sensitive output.

Never interpret the existence of a command containing `cache` as proof that it is safe.

Never silently switch to recursive directory deletion after a native command fails.

## 7. Safety Model

### Analysis must be non-destructive

Analysis may:

- Detect installed tools.
- Read supported configuration.
- Enumerate candidate paths.
- Measure directory sizes where practical.
- Identify unsupported or ambiguous targets.
- Explain what cleanup would do.

Analysis must not delete or modify cache contents.

### Filesystem path validation

Before filesystem deletion:

- Normalize and validate the target path.
- Confirm that it belongs to the expected target-specific scope.
- Reject filesystem roots, drive roots, user profile roots, Windows system roots, and other protected locations unless a narrowly scoped, explicitly supported operation requires them.
- Detect and safely handle symbolic links, junctions, and reparse points.
- Never recursively follow links outside the approved scope.
- Reject ambiguous, malformed, or unexpectedly broad paths.
- Handle races and inaccessible files defensively.
- Never pass an unchecked path from an environment variable directly into a recursive deletion command.

An environment variable is not proof that a path is safe.

### Confirmation and privileges

- Never automatically request administrator privileges.
- Do not change PowerShell execution policy or modify PATH.
- Require clear confirmation for destructive operations.
- Explain the selected target and consequences before confirmation.
- `--force` may bypass only explicitly documented confirmation prompts.
- `--force` must never bypass path validation, target restrictions, safety checks, or unsupported-operation checks.

## 8. CLI Requirements

The CLI command is `resik`. Resik uses GNU-style options: a double-dash long form for every option, plus a single-letter short form for common ones. All option names are lowercase and case-sensitive, consistently in the implementation, help output, documentation, examples, and tests.

Use these command examples:

```powershell
resik --help
resik --version
resik
resik --dry-run
resik --all
resik --only uv,pip,scoop
resik --non-interactive --all --dry-run
resik --report-path .\resik-report.json
```

### Options

- `-h`, `--help`: Show usage and supported options.
- `-v`, `--version`: Show the application version.
- `-n`, `--dry-run`: Analyze selected targets without performing cleanup.
- `-a`, `--all`: Select all supported, eligible cleanup targets.
- `-o`, `--only <ids>`: Select specific target IDs.
- `--non-interactive`: Disable interactive prompts and require explicit selection where needed.
- `--report-path <path>`: Write an optional JSON report to the specified path.
- `-f`, `--force`: Bypass only explicitly documented confirmation prompts. Never bypass safety checks.

Value options accept `--only uv,pip`, `--only=uv,pip`, and `-o uv,pip`. Short options cannot be bundled (`-na` is an error). Single-dash long forms such as `-dryrun` and differently cased forms such as `--Help` are rejected with a suggestion of the correct spelling.

PowerShell's parameter binder cannot declare `--name` options, so `Resik.ps1` has no param block and parses `$args` itself (`Core/Arguments.ps1`). `Get-ResikOptionSpec` is the single source of truth for option names. Parsing must behave identically when invoked in-process (Scoop's `.ps1` shim; PowerShell turns `uv,pip` into an array and splits `--only=uv,pip` at the comma) and through `powershell -File` (Scoop's `.cmd` shim). PowerShell consumes a bare `--` before the script sees it, so do not rely on `--` as an end-of-options marker.

Validate incompatible arguments and unknown target IDs. Display actionable errors instead of silently ignoring invalid input.

### Cleanup confirmation

Without `--dry-run`, Resik analyzes the selected targets, prints the cleanup plan (`Format-ResikCleanupPlan`), and asks `Clean these targets? [y/N]` (`Read-ResikConfirmation`). That is the only prompt `--force` skips. With `--non-interactive`, or when `Test-ResikInteractiveInput` is false (redirected input), cleanup without `--force` exits `2` before anything is cleaned. Only targets whose analysis returned `AnalysisOnly` and that have `Clean` are cleaned. A declined prompt exits `0`; a `Failed` or `PartialSuccess` cleanup exits `1`.

### Dry-run guarantees

`--dry-run` must never execute a destructive cleanup operation.

For native tools:

- Run only commands documented as inspection, listing, or preview operations.
- Do not invoke cleanup commands and assume they will merely report their intended changes.
- If a tool has no safe preview capability, report that the exact cleanup result cannot be previewed.
- Do not delete files or change package-manager state.

### Interactive target selection

Provide keyboard-driven selection:

- Up/Down: Navigate.
- Space: Toggle selection.
- A: Select all eligible targets.
- N: Deselect all.
- Enter: Confirm selection.
- Q or Escape: Cancel.

Show the target name, category, availability, risk level, and estimated reclaimable space when available.

If interactive terminal features are unavailable, use a numbered-list fallback or require explicit non-interactive arguments.

### Progress display

Any step that can take more than a moment (analysis, measuring a cache, waiting for a tool's clean command) shows a spinner with a message naming the current step and its elapsed seconds. It is shown only when `Test-ResikSpinnerSupported` is true: a `ConsoleHost`, output not redirected, a readable window width, and `FullLanguage` mode. Otherwise `Start-ResikSpinner` returns `$null` and the other spinner functions do nothing, so redirected output and logs never contain spinner frames. The spinner never replaces the plain lines that say what is happening (`Analyzing targets...`, `Running: <command>`); those still appear in logs.

### Interactive picker flow

Without `--all` or `--only` (for example bare `resik`, `resik --dry-run`, or `resik --force`), Resik analyzes every target and opens the picker (`Invoke-ResikInteractiveRun`). Only targets whose analysis returned `AnalysisOnly` and that have `Clean` can be selected; others are shown as `[-]` with the reason. Nothing is preselected. `Get-ResikPickerMode` chooses `Keys` (the full picker, in a console host), `Numbered` (typed numbers, for hosts without key input), or `None` (redirected input), in which case Resik exits `2` before analyzing. A picked selection still goes through the cleanup confirmation below. `--non-interactive` without a selection is a usage error.

## 9. Result Model and Reporting

Use consistent statuses:

- `Success`
- `PartialSuccess`
- `Failed`
- `Skipped`
- `AnalysisOnly`
- `Unsupported`
- `Unknown`

Each result should include the target, operation, status, useful diagnostics, and timing where practical.

Distinguish:

1. **Estimated reclaimable space:** estimated during analysis.
2. **Measured cache reduction:** observed change in the target's cache contents.
3. **Net free disk-space increase:** observed change in available disk space, which can differ due to concurrent activity.

Never label estimates as actual reclaimed space.

### JSON reports

When `--report-path` is specified:

- Produce valid JSON with a documented schema.
- Include application version, timestamp, selected targets, statuses, and measurements where available.
- Distinguish missing measurements from zero.
- Exclude credentials, secrets, and unnecessary personal information.
- Validate the destination path.
- Do not overwrite existing reports without appropriate protection or explicit consent.
- Report failures to write the report.

## 10. Testing Requirements

Use Pester for development tests when available. It is not a runtime dependency for ordinary users.

Tests must not clean real user caches or delete actual Windows files.

Use temporary directories and mocked external commands for destructive-operation tests.

At minimum, test:

- Target registration and discovery.
- Missing tools and unsupported targets.
- CLI parameter validation.
- Interactive selection logic.
- Dry-run non-destructive behavior.
- Path validation and protected-path rejection.
- Symbolic links, junctions, and reparse points.
- Native command argument handling.
- Native command exit codes, timeouts, and error output.
- Per-target failure isolation.
- Result status classification.
- JSON report validity and write failures.
- Existing-file overwrite protection.
- Locked and inaccessible files.
- Separation of estimates from measured results.

For Scoop, verify that:

- The cleanup and download-cache operations are represented as separate targets or separately reported operations.
- The expected command and argument lists are passed correctly.
- Commands are not executed in dry-run mode.
- A failed operation is reported accurately.
- Tests do not execute actual Scoop cleanup commands.

Add GitHub Actions CI for automated tests and static checks. CI must not perform real cleanup operations or require access to developer machines.

Never claim a test passed unless it was executed and its results inspected.

### Test conventions

- Tests require Pester 5. Windows ships Pester 3.4, whose syntax is incompatible; import Pester 5 explicitly (`Import-Module Pester -MinimumVersion 5.5.0`).
- Every test file dot-sources `tests/TestSetup.ps1` in `BeforeAll`. It loads the same source files as `Resik.ps1`, enables the same strict mode, and provides `New-TestTarget` for fake targets.
- CLI behavior that depends on how arguments arrive must also be tested end to end, by running `Resik.ps1` in a child process both with `-File` and in-process with `&`, matching Scoop's two shims.
- Assert exact error messages where a wildcard could hide a missing value. In `-like` patterns, `?` and `*` are wildcards.
- `Cli.Tests.ps1` checks that every `resik ...` example in `README.md`, `docs/RELEASING.md`, and the help text uses only real options. Keep examples on lines that start with `resik`.
- CI (`.github/workflows/ci.yml`) runs PSScriptAnalyzer with `PSScriptAnalyzerSettings.psd1` and the Pester suite on both Windows PowerShell 5.1 and PowerShell 7.

## 11. PowerShell Quality Standards

- Use explicit, maintainable PowerShell code.
- Avoid unnecessary global state.
- Keep functions focused and testable.
- Handle native executable arguments safely.
- Capture stdout, stderr, exit codes, and timeouts where appropriate.
- Account for supported PowerShell and Windows differences.
- Avoid undocumented behavior.
- Make encoding and JSON serialization explicit.
- Preserve useful errors without leaking secrets.
- Use PSScriptAnalyzer or suitable static analysis tools when available.

### Project conventions and known pitfalls

- Windows PowerShell 5.1 is the baseline; PowerShell 7 must also work. Keep source files ASCII, because 5.1 misreads UTF-8 files without a BOM.
- `Resik.ps1` runs under `Set-StrictMode -Version 3.0` and `$ErrorActionPreference = 'Stop'`. Code must not read unset variables or missing properties. Use `Get-ResikOptionalProperty` for properties that may be absent.
- `?` is a valid variable-name character, so `"$name?"` reads a variable named `name?`. Write `"${name}?"`.
- Functions that return collections emit their items normally (no leading `,`). Callers wrap the call in `@()` when they need an array. Mixing the two styles produces nested arrays.
- Inside `@( ... )`, each newline-separated `@(...)` row is unrolled into the outer array. Build tables of records with objects or a constructor function instead.
- Raise command-line usage errors as `System.ArgumentException`; `Invoke-ResikCli` reports them without a stack trace. Exit codes: `0` success, `1` a target failed or an unexpected error occurred, `2` invalid or unsupported usage.
- A scriptblock made with `.GetNewClosure()` runs in its own module scope and cannot see `$script:` variables. Capture what it needs in local variables first. For the same reason, source files define no script-level variables; keep constants inside functions.
- Run external tools only through `Invoke-ResikNativeCommand` with a path from `Resolve-ResikExecutable`. Never use `&`, `Start-Process`, or string-built command lines for tools. Prefer `.exe`. Tools that ship only as batch files (Scoop, npm) use `-Extension '.cmd'`; because `cmd.exe` re-parses their arguments, the runner refuses any argument that is not a plain token (`Test-ResikBatchArgument`: no spaces, quotes, or `& | < > ^ % ! ( )`), so never pass paths to them. On timeout or Ctrl+C the runner stops the whole process tree, since a `.cmd` starts further processes.
- A function that returns a one-item array returns the item itself (PowerShell unrolls it), so code that reads JSON arrays through helpers such as `Get-ResikOptionalProperty` must also accept a single string.
- In a Pester `-ParameterFilter`, a parameter the caller did not pass is `$null`, not its default value. Filter on `$Extension -ne '.cmd'` rather than `$Extension -eq '.exe'`.
- Never run the `python.exe` in `%LOCALAPPDATA%\Microsoft\WindowsApps` unless a Store Python is installed (`Test-ResikWindowsAppsPythonStub`); it is a stub that opens the Microsoft Store.
- Nothing may write to the console while a spinner is running; the two would garble the line. Start it after printing, change its text with `Set-ResikSpinnerMessage`, and call `Stop-ResikSpinner` in a `finally` block (it clears the line and restores the cursor, and is safe with `$null` or when called twice), so an error or Ctrl+C never leaves it drawing in the user's session. The spinner's runspace has no Resik functions and no cmdlets: its script (`Get-ResikSpinnerScript`) uses .NET calls only, and it gets an empty session state with `FullLanguage`, which is why it is never started unless Resik itself runs in `FullLanguage`. Its frames are ASCII (`| / - \`) because Windows PowerShell 5.1 consoles often use a code page without Unicode symbols.
- `tests/TestSetup.ps1` redefines `Test-ResikSpinnerSupported` to return `$false`, so tests run in a real console never draw. `Spinner.Tests.ps1` reloads `Spinner.ps1` to test the real functions.
- Tests that start `Resik.ps1` in a child process pipe `n` to its standard input (`Invoke-ResikProcess`), so a child can never be confirmed into real cleanup. Tests that run a real tool's clean command must first assert that the tool points at a `TestDrive` path.
- Factory functions such as `New-ResikTarget` suppress `PSUseShouldProcessForStateChangingFunctions` individually with a justification. Do not disable that rule globally; it must stay active for cleanup code. `PSAvoidUsingWriteHost` is disabled globally because Resik is a console tool.

## 12. Git Workflow

Commit directly to `main`; feature branches and pull requests are not required. Because nothing reviews a change before it lands, the local checks below must pass first, and CI is checked after every push.

1. Inspect the current branch and working tree.
2. Implement one logical feature or fix.
3. Run the Pester suite on both Windows PowerShell 5.1 and PowerShell 7, and PSScriptAnalyzer.
4. Inspect `git diff --check`, the full diff, and newly created untracked files.
5. Summarize changes, risks, and validation results.
6. Ask for explicit approval before committing or pushing.
7. After approval, stage only reviewed files.
8. Inspect the staged diff.
9. Commit to `main` with a concise, descriptive message.
10. Push `main` to the configured remote, then check that CI passes and fix any failure promptly.

Do not:

- Commit unrelated user changes.
- Stage secrets or generated local artifacts.
- Force-push or rewrite history without explicit authorization.
- Commit, push, or publish a release before approval.
- Claim a push succeeded unless it actually succeeded.

Prefer small, reviewable changes over large rewrites.

## 13. Releases and Scoop Distribution

Resik is distributed through GitHub Releases and a personal Scoop bucket maintained separately:

```
https://github.com/rendicahya/scoop-bucket
```

The bucket repository contains Scoop manifests, not Resik source code.

Resik's own repository owns its source code, tests, documentation, release artifacts, and release notes.

For releases:

- Use versioned Git tags and GitHub Releases.
- Follow semantic versioning where appropriate.
- Ensure release artifacts are reproducible or their build process is documented.
- Calculate SHA-256 hashes from actual artifacts.
- Never invent download URLs or hashes.
- Document supported Windows and PowerShell versions.
- Test installation, execution, updating, and uninstallation where feasible.
- Keep uninstallation separate from cache cleanup.
- Never clean user caches during installation, updating, or uninstallation.
- Do not modify the Scoop bucket automatically without explicit authorization and verified release information.
- Do not require Git to be installed on end-user machines.

### Release mechanics

Follow `docs/RELEASING.md`. In short:

- The version lives only in `Get-ResikVersion` (`src/Resik/Core/Cli.ps1`). Tag releases as `v<version>`.
- `tools/Build-Release.ps1` writes `dist/resik-<version>.zip` (Git-ignored), with the contents of `src/Resik` (`Resik.ps1` and every subfolder), `LICENSE`, and `README.md` at the archive root. It refuses pre-release versions and existing archives.
- Zip archives embed timestamps, so builds are not byte-for-byte reproducible. Put into the manifest the SHA-256 of the asset downloaded from the published GitHub Release, never the hash of a local rebuild.
- Users add the bucket as `personal`. The manifest is `bucket/resik.json` and exposes the command with `"bin": [["Resik.ps1", "resik"]]`. Scoop then creates a `.ps1` shim (runs Resik in-process) and a `.cmd` shim (runs `powershell -File`), so option parsing must work both ways.
- Test a manifest with `scoop install .\bucket\resik.json` before it is merged into the bucket.

## 14. Documentation

Keep documentation aligned with implemented behavior.

Document:

- Supported Windows and PowerShell versions.
- Installation and removal.
- Available cleanup targets and their risks.
- Interactive and non-interactive usage.
- Dry-run behavior and limitations.
- Reporting.
- Known limitations.
- Development setup and tests.
- Release and Scoop distribution procedures.

Do not describe a target as supported until its implementation and safety checks exist.

## 15. Incremental Implementation Strategy

Recommended order:

1. Inspect the repository and establish the baseline.
2. Implement the CLI foundation and target/result models.
3. Implement safe analysis and dry-run behavior.
4. Implement interactive selection.
5. Implement JSON reporting.
6. Add a small number of well-understood cleanup targets.
7. Add tests and CI.
8. Add developer-tool targets one at a time.
9. Validate installation and release packaging.
10. Expand documentation as features become available.

Prioritize safety, testability, and verifiable behavior over the number of supported tools.

Do not implement every target in one massive change.

## 16. How to Work on Tasks

At the start of a task:

- Inspect the repository, Git status, relevant source code, tests, and documentation.
- Identify the smallest coherent change.
- Briefly explain important assumptions and safety implications.

During implementation:

- Preserve existing behavior unless an intentional change is required.
- Follow the architecture and safety model.
- Add or update tests for changed behavior.
- Avoid unrelated refactoring.

Before finishing:

- Run relevant available tests and checks.
- Review changed and newly created files.
- Run `git diff --check`.
- Report what was implemented, what was tested, failures, and remaining work.
- Show relevant Git commands when appropriate.
- Do not commit, push, or publish a release without explicit approval.

When requirements are ambiguous, choose the safer behavior and document the limitation. Ask questions only when an essential decision cannot be resolved safely from the repository or authoritative documentation.
