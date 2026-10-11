# CLAUDE.md — Resik

## 1. Project Overview

Resik is a native Windows cleanup utility that helps users analyze and reclaim disk space from Windows and developer-tool caches.

- **Application:** Resik
- **CLI command:** `resik`
- **Platform:** Windows 10 and Windows 11
- **Implementation:** Native PowerShell
- **Runtime dependencies:** Windows and PowerShell; no required Python, Node.js, or third-party runtime.
- **Distribution:** GitHub Releases and a personal Scoop bucket.
- **Development workflow:** GitHub Flow.

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
- Do not execute these commands during `-DryRun`.
- Do not assume that `-DryRun` is supported by these Scoop commands.

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
- `-Force` may bypass only explicitly documented confirmation prompts.
- `-Force` must never bypass path validation, target restrictions, safety checks, or unsupported-operation checks.

## 8. CLI Requirements

The CLI command is `resik`. All Resik CLI flags must use lowercase names consistently in the implementation, help output, documentation, examples, and tests.

Use these command examples:

```powershell
resik -help
resik -version
resik
resik -dryrun
resik -all
resik -only uv,pip,scoop
resik -noninteractive -all -dryrun
resik -reportpath .\resik-report.json
```

### Parameters

- `-help`: Show usage and supported options.
- `-version`: Show the application version.
- `-dryrun`: Analyze selected targets without performing cleanup.
- `-all`: Select all supported, eligible cleanup targets.
- `-only`: Select specific target IDs.
- `-noninteractive`: Disable interactive prompts and require explicit selection where needed.
- `-reportpath`: Write an optional JSON report to the specified path.
- `-force`: Bypass only explicitly documented confirmation prompts. Never bypass safety checks.

All flag names must remain lowercase in user-facing output. Do not use PascalCase variants such as `-DryRun` or `-NonInteractive` in examples or documentation.

Use consistent parameter handling in PowerShell. Account for PowerShell's case-insensitive parameter matching, but standardize all documented and generated command examples on lowercase flags.

Validate incompatible arguments and unknown target IDs. Display actionable errors instead of silently ignoring invalid input.

### Dry-run guarantees

`-dryrun` must never execute a destructive cleanup operation.

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

When `-ReportPath` is specified:

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

## 12. GitHub Flow

Use GitHub Flow for all development.

1. Inspect the current branch and working tree.
2. Create a feature branch for each focused change when appropriate.
3. Implement one logical feature or fix.
4. Run relevant tests and static checks.
5. Inspect `git diff --check`, the full diff, and newly created untracked files.
6. Summarize changes, risks, and validation results.
7. Ask for explicit approval before committing or pushing.
8. After approval, stage only reviewed files.
9. Inspect the staged diff.
10. Commit with a concise, descriptive message.
11. Push only to the intended branch and configured remote.

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
