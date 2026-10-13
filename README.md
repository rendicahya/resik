# resik
A safe, native PowerShell cleanup utility for Windows and developer-tool caches.

> **Status: early development.** Resik cleans the caches of uv, pip, Conda,
> Hugging Face, npm, Scoop, Chocolatey, and NuGet, and Playwright's browsers.
> For Gradle, Maven, and JetBrains IDEs it only reports sizes. It never cleans
> anything without showing you the plan first and asking for confirmation.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (included with Windows). PowerShell 7 is also exercised in CI.

No Python, Node.js, or other runtime is required.

## Installation

> Resik 0.1.0 has not been published yet. Until it is, the commands below will
> not find Resik; [run it from source](#running-from-source) instead.

Install with [Scoop](https://scoop.sh/) from the `personal` bucket:

```powershell
scoop bucket add personal https://github.com/rendicahya/scoop-bucket
scoop install personal/resik
```

Update or remove it with:

```powershell
scoop update resik
scoop uninstall resik
```

Installing, updating, and uninstalling Resik never cleans any caches.

## Running from source

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Resik\Resik.ps1 --help
```

`-ExecutionPolicy Bypass` applies only to that single process; Resik never changes
your execution policy.

## Usage

The examples use the `resik` command name. When running from source, substitute
the `powershell ... -File .\src\Resik\Resik.ps1` invocation shown above.

Run `resik` with no options to pick what to clean from a list:

```
Select targets to clean
Up/Down: move  Space: select  A: all  N: none  Enter: confirm  Q/Esc: cancel

> [x] uv           uv cache                Developer  Low risk  370.6 MB
  [x] pip          pip cache               Developer  Low risk  300.5 MB
  [ ] npm          npm cache               Developer  Low risk  1.9 GB
  [ ] scoop-apps   Scoop old app versions  Developer  Low risk  0 B
  [ ] scoop-cache  Scoop download cache    Developer  Low risk  0 B
  [ ] choco        Chocolatey HTTP cache   Developer  Low risk  n/a
  [-] nuget        NuGet HTTP cache        Developer  Low risk  not found

  C:\Users\you\AppData\Local\uv\cache (5145 files)
  Selected: 2 target(s), estimated 671.1 MB
```

Targets that are not installed, whose analysis failed, or that Resik only
measures (see [Analysis only](#analysis-only)) are shown as `[-]` and cannot
be selected; the line under the list explains why.
Nothing is selected at first. After you press Enter, Resik shows what it will
remove and asks for confirmation. In terminals that cannot read single key
presses, such as the VS Code PowerShell extension's host, Resik shows a numbered
list and asks you to type the numbers instead.

Options select targets directly, for scripts and repeat use:

```powershell
resik
resik --dry-run
resik --dry-run --all
resik --only uv
resik --non-interactive --force --only uv
resik --help
resik --version
```

| Option | Description |
| --- | --- |
| `-h`, `--help` | Show usage and supported options. |
| `-v`, `--version` | Show the Resik version. |
| `-n`, `--dry-run` | Analyze targets without changing anything. With the picker, pick what to analyze. |
| `-a`, `--all` | Select all targets except `scoop-persist`, without the picker. |
| `-o`, `--only <ids>` | Select specific target IDs (comma-separated), without the picker. |
| `--non-interactive` | Never prompt. Requires `--all` or `--only`, and `--force` to clean. |
| `--report-path <path>` | Write a JSON report. Not implemented yet; rejected with an error. |
| `-f`, `--force` | Skip the cleanup confirmation prompt. Never bypasses safety checks. |

Options are lowercase and case-sensitive. Values can be given as `--only uv,pip`,
`--only=uv,pip`, or `-o uv,pip`. Short options cannot be combined (`-na` is an
error).

### How cleanup works

1. Resik analyzes the targets and shows the estimated size of each, either in
   the picker or, with `--all` or `--only`, as a table. Measuring large caches
   can take a while, so a spinner shows which target is being analyzed and for
   how long.
2. It lists what will be cleaned, where, and the consequences.
3. It asks `Clean these targets? [y/N]`. Only `y` or `yes` continues. This is
   the only prompt that `--force` skips. With `--non-interactive`, or when input
   is redirected, cleanup requires `--force`.
4. Each target is cleaned independently; one failure does not stop the others.
   Resik prints the command it runs, and a spinner shows that it is still
   working while the command runs and while Resik measures the result.
5. Resik reports the measured cache reduction and the change in free disk space
   separately. They can differ, because files hard-linked into environments stay
   on disk, and other programs write to the disk at the same time.

With `--dry-run`, only steps 1 and 2 happen, and nothing is changed.

### Targets

Every target in the table below cleans through the tool's own documented
command; Resik does not delete those cache files itself. Before running it, Resik asks the tool where its
cache is and refuses locations that are drive roots, system or user-profile
folders (or folders containing them), or symbolic links and junctions.

| ID | What it cleans | Command Resik runs | Risk |
| --- | --- | --- | --- |
| `uv` | The [uv](https://docs.astral.sh/uv/) cache | `uv cache clean --cache-dir <dir>` | Low |
| `pip` | Downloaded and locally built packages in the pip cache | `python -m pip cache purge --cache-dir <dir>` | Low |
| `conda` | Unused packages, package downloads, index cache, and logs | `conda clean --all --yes` | Medium |
| `huggingface` | Hugging Face Hub revisions no branch or tag uses, and interrupted downloads | `hf cache prune --yes --cache-dir <dir>` | Low |
| `npm` | npm's package cache (`<cache>\_cacache`) | `npm cache clean --force` | Low |
| `playwright` | Browsers that Playwright downloaded | `playwright uninstall --all` | Medium |
| `scoop-apps` | Old versions of installed Scoop apps | `scoop cleanup *` | Low |
| `scoop-cache` | Installers in Scoop's download cache | `scoop cache rm *` | Low |
| `choco` | Your Chocolatey HTTP cache | `choco cache remove --yes` | Low |
| `nuget` | The NuGet HTTP cache | `dotnet nuget locals http-cache --clear` | Low |

What these remove is downloaded again when needed. Details:

- **uv:** the location comes from `uv cache dir` (which honors `UV_CACHE_DIR`
  and uv configuration), and must contain the `CACHEDIR.TAG` file uv writes.
  Projects and virtual environments are not deleted, but environments created
  with `--link-mode=symlink` point into the cache and stop working. If another
  uv process is using the cache, uv waits for it; press Ctrl+C to stop.
- **pip:** the pip cache is shared by your Python installations, so Resik uses
  the first working one of: `python` on PATH, the `py` launcher, or a
  uv-managed Python. It never runs the `python.exe` stub that Windows installs
  to open the Microsoft Store. Installed packages are not touched.
- **conda:** finds `conda.exe` on PATH or through `CONDA_EXE` (set by
  `conda init`). The estimate comes from `conda clean --all --dry-run --json`
  and covers unused packages and downloads; the index cache and logs are
  removed too but not estimated. Environments are kept. Conda counts a package
  as unused when no environment it knows about (`conda info --envs`) links to
  it, so an environment it does not list could lose files; hence Medium risk.
  `--force-pkgs-dirs` is never used.
- **huggingface:** needs the `hf` command (huggingface_hub 2.x). The cache is
  `HF_HUB_CACHE`, else `HF_HOME\hub`, else `~\.cache\huggingface\hub`. Only
  revisions that no branch or tag points to, unfinished downloads, and shared
  files that no repo uses are removed (`hf cache prune`); the models and
  datasets you use are kept, and so are your login tokens. The estimate comes
  from `hf cache prune --dry-run` and is rounded.
- **npm:** only `_cacache` is removed; the npx cache and logs next to it, and
  every `node_modules` folder, are kept.
- **playwright:** these are browser installations, not a cache. Removing them
  breaks Playwright tests and scripts until you run `playwright install`, which
  downloads them again. Needs the `playwright` command on PATH (the Python
  package, or a global npm install); Resik never runs `npx`, which could
  download Playwright first. Without it, run `npx playwright uninstall --all`
  in a project yourself. The browsers folder is `PLAYWRIGHT_BROWSERS_PATH`,
  else `%LOCALAPPDATA%\ms-playwright`. Google Chrome and Microsoft Edge are
  not affected.
- **scoop-apps:** keeps the current version and persisted data of every app,
  but you can no longer `scoop reset` to an old version. An app that is running
  can stop the cleanup part-way; Resik then reports partial success. Global
  apps (which need administrator rights) are not cleaned.
- **scoop-cache:** Resik estimates and verifies the result from the cache folder
  (`SCOOP_CACHE`, Scoop's `cache_path` setting, or `<scoop>\cache`), because
  Scoop reports success even when it cannot delete a file.
- **choco:** without administrator rights (Resik never elevates) only your user
  HTTP cache is cleaned. Chocolatey reports item counts but not sizes or the
  cache location, so Resik shows no size for it. Installed packages are not touched.
- **nuget:** needs a .NET SDK. Only the HTTP cache is cleared. The
  global-packages folder is never cleared, because projects use packages
  directly from it, and neither is NuGet's temp folder, which coordinates
  running restores.

#### Leftover app data (chosen one by one)

| ID | What it removes | How | Risk |
| --- | --- | --- | --- |
| `scoop-persist` | Folders in `<scoop>\persist` of apps that are no longer installed | Resik deletes each folder you confirm | High |

When you uninstall a Scoop app without `--purge`, Scoop keeps its settings and
data in `<scoop>\persist\<app>` so a reinstall can reuse them. Scoop has no
command to remove that data once the app is gone, so this is the one target
where Resik deletes files itself:

- A folder counts as leftover when `<scoop>\apps` has no folder of that name.
  Links in `persist` are ignored, and global apps are not checked.
- `--all` and "select all" in the picker never choose it; name it with
  `--only scoop-persist` or select it yourself.
- During cleanup Resik asks about each folder separately, showing its name,
  size, and path. `--force` does not answer these questions, and without a
  terminal nothing is removed. Before deleting, Resik checks again that the
  app is still not installed.
- The deletion never follows symbolic links or junctions, and stays inside
  `persist`. Files that are in use are skipped and reported.
- This data cannot be downloaded again. For some portable apps it is
  everything you saved in them.

#### Analysis only

These targets show their size but cannot be selected for cleaning, because
the tools have no command that safely cleans them. Their sizes are not added
to the estimated reclaimable space.

| ID | What it measures | How to clean it yourself |
| --- | --- | --- |
| `gradle` | Caches, wrapper distributions, and daemon logs in `GRADLE_USER_HOME` (default `~\.gradle`) | Gradle removes entries unused for 30 days by itself |
| `maven` | The local repository (`localRepository` in `~\.m2\settings.xml`, default `~\.m2\repository`) | It holds your projects' dependencies and locally installed artifacts; delete only what you know you no longer need |
| `jetbrains` | The `caches` and `index` folders of each IDE version in `%LOCALAPPDATA%\JetBrains` | In the IDE: File \| Invalidate Caches, or Help \| Delete Leftover IDE Directories |

Not detected: a Maven `localRepository` set only in the Maven installation's
settings or with `-Dmaven.repo.local`, IDEs moved with `idea.system.path`, and
Android Studio.

Not supported: WinGet has no cache-cleaning command. pnpm and Yarn are planned.

The picker needs a terminal. When input is redirected (for example in a
scheduled task), `resik` without `--all` or `--only` exits with an error.
The spinner appears only in a console window. When output is redirected to a
file or a pipe, it is left out, so logs contain no animation.

Exit codes: `0` success (including a cancelled picker or a declined
confirmation), `1` one or more
targets failed or only partly succeeded, or an unexpected error occurred, `2`
invalid or unsupported command-line usage (including cleanup that needs
`--force`).

## Development

Layout:

```
src/Resik/
  Resik.ps1               CLI entry point
  Core/
    Arguments.ps1         option parsing (-h, --help, --only=...)
    Cli.ps1               version, help text, orchestration, exit codes
    Models.ps1            target and result models
    Selection.ps1         --all / --only target selection
    Analysis.ps1          non-destructive analysis with per-target isolation
    NativeCommand.ps1     runs external tools with captured output and timeouts
    FileSystem.ps1        path safety checks, size and free-space measurement
    Cleanup.ps1           cleanup with per-target isolation
    Deletion.ps1          link-safe folder deletion (used only by scoop-persist)
    Catalog.ps1           registered cleanup targets
  DeveloperCleanup/       one file per tool: Uv, Pip, Conda, HuggingFace, Npm,
                          Playwright, Scoop, Chocolatey, NuGet, and the
                          analysis-only Gradle, Maven, JetBrains
  Reporting/
    ConsoleReport.ps1     console summaries
  UI/
    TargetPicker.ps1      interactive checkbox picker and numbered fallback
    Spinner.ps1           progress spinner for long steps
tests/                    Pester 5 tests (TestSetup.ps1 loads the sources)
tools/Build-Release.ps1   builds the release archive
docs/RELEASING.md         release and Scoop procedure
```

Tests use [Pester](https://pester.dev/) 5 and static analysis uses
[PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer). Neither is
needed to run Resik. Windows ships with Pester 3.4, which is too old, so install
Pester 5 for your user:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

Run the checks from the repository root:

```powershell
Import-Module Pester -MinimumVersion 5.5.0
Invoke-Pester -Path .\tests
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

The `Import-Module` line makes sure Pester 5 is used instead of the built-in 3.4.

Tests use fake targets, mocked commands, and temporary directories. They never
clean real caches, and the Scoop tests point Scoop's environment variables and
config location at temporary folders. If uv is installed, one test runs the real `uv cache clean` on
a throwaway cache in Pester's `TestDrive`, after checking that uv points there.
They run under the same strict mode as Resik itself, and CI runs them on both
Windows PowerShell 5.1 and PowerShell 7.

## License

MIT. See [LICENSE](LICENSE).
