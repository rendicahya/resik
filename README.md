# resik
A safe, native PowerShell cleanup utility for Windows and developer-tool caches.

> **Status: early development.** Resik empties the Recycle Bin, clears the
> DirectX shader and thumbnail caches, runs Windows Update cleanup, and cleans
> the caches of uv, pip, Poetry, Conda,
> Hugging Face, PyTorch Inductor, Triton, npm, pnpm, Yarn, Composer, Go, Scoop,
> Chocolatey, and NuGet, and Playwright's browsers.
> For Gradle, Maven, and JetBrains IDEs it only reports sizes. It never cleans
> anything without showing you the plan first and asking for confirmation.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (included with Windows). PowerShell 7 is also exercised in CI.

No Python, Node.js, or other runtime is required.

## Installation

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
Up/Down move   Space select   A all   N none   Enter confirm   Q cancel

      Target                                Size  Risk
> [x] uv           uv cache               1.9 GB  Low
  [x] npm          npm cache            370.6 MB  Low
  [ ] pip          pip cache            300.5 MB  Low
  [ ] scoop-cache  Scoop download cache   1.2 MB  Low
  [ ] choco        Chocolatey HTTP cache       ?  Low
  [-] jetbrains    JetBrains IDE caches 520.4 MB  Low     report only

  ~\AppData\Local\uv\cache (5145 files)
  Selected: 2 targets, about 2.3 GB
```

Targets that can be cleaned come first, largest first. Targets whose analysis
failed, or that Resik only measures (see [Analysis only](#analysis-only)), are
shown as `[-]` and cannot be selected; tools that are not installed are not
shown. `?` means the size cannot be measured in advance, and `~` is
your user profile folder. The line under the list shows details for the target
under the cursor.
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
| `-a`, `--all` | Select all targets except `recycle-bin`, `scoop-persist`, and `jetbrains-leftovers`, without the picker. |
| `-o`, `--only <ids>` | Select specific target IDs (comma-separated), without the picker. |
| `--non-interactive` | Never prompt. Requires `--all` or `--only`, and `--force` to clean. |
| `--report-path <path>` | Write a JSON report. Not implemented yet; rejected with an error. |
| `-f`, `--force` | Skip the cleanup confirmation prompt. Never bypasses safety checks. |

Options are lowercase and case-sensitive. Values can be given as `--only uv,pip`,
`--only=uv,pip`, or `-o uv,pip`. Short options cannot be combined (`-na` is an
error).

### How cleanup works

1. Resik analyzes the targets and shows the estimated size of each, either in
   the picker or, with `--all` or `--only`, as a report grouped into targets
   ready to clean and report-only targets. Tools that are not installed are
   left out, except that `--only` names the ones you asked for. Measuring large caches
   can take a while, so a spinner shows which target is being analyzed and for
   how long.
2. It lists what will be cleaned, where, and the consequences.
3. It asks `Clean these targets? [y/N]`. Only `y` or `yes` continues. This is
   the only prompt that `--force` skips. With `--non-interactive`, or when input
   is redirected, cleanup requires `--force`.
4. Each target is cleaned independently; one failure does not stop the others.
   Resik prints the command it runs, and a spinner shows that it is still
   working while the command runs and while Resik measures the result.
5. Resik reports the results grouped into cleaned, partly cleaned, failed, and
   not cleaned targets, with the measured cache reduction and the change in
   free disk space shown separately. They can differ, because files hard-linked into environments stay
   on disk, and other programs write to the disk at the same time.

With `--dry-run`, only steps 1 and 2 happen, and nothing is changed.

### Targets

#### Windows

| ID | What it cleans | How | Risk |
| --- | --- | --- | --- |
| `recycle-bin` | Your Recycle Bin on every drive | `Clear-RecycleBin -Force` | High |
| `directx-shaders` | Compiled DirectX shaders in `%LOCALAPPDATA%\D3DSCache` | Resik deletes the folder's contents | Low |
| `thumbnails` | File Explorer's thumbnail cache (`thumbcache_*.db`) | Resik deletes the matching files | Low |
| `windows-update` | Component-store copies of updates that newer updates replaced | `Dism.exe /Online /Cleanup-Image /StartComponentCleanup` | Medium |

- **recycle-bin:** the deleted files cannot be restored afterwards, so `--all`
  and "select all" in the picker never choose it; name it with
  `--only recycle-bin` or select it yourself. The size comes from your own
  `<drive>:\$Recycle.Bin\<SID>` folders; other users' bins are not touched.
- **directx-shaders, thumbnails:** Windows has no command for these, so Resik
  deletes the files itself, the same ones Disk Cleanup removes. Links are not
  followed, and files in use (by a running game, or by File Explorer, which
  keeps some thumbnail files open) are skipped and reported. Windows rebuilds
  both caches: games may stutter the first time, and folders show thumbnails
  again as you browse. The icon cache and driver shader caches (NVIDIA, AMD)
  are not touched.
- **windows-update:** needs administrator rights. Resik never elevates itself,
  so without them this target is report-only; open a terminal with "Run as
  administrator" to clean it. DISM cannot preview what it will remove, so no
  estimate is shown; the result is the change in free space on the system
  drive. `/ResetBase` is never used, so installed updates can still be
  uninstalled. It can take 10 minutes or more.

#### Developer tools

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
| `poetry` | Poetry's repository caches (package metadata and downloads) | `poetry cache clear <name> --all --no-interaction` per cache | Low |
| `npm` | npm's package cache (`<cache>\_cacache`) | `npm cache clean --force` | Low |
| `pnpm` | Packages in the pnpm store that no project uses | `pnpm store prune` | Low |
| `yarn` | The global Yarn Classic (1.x) cache | `yarn cache clean` | Low |
| `composer` | Composer's cache (packages, repository metadata, VCS clones) | `composer global clear-cache --no-interaction` | Low |
| `go-build` | The Go build cache (`GOCACHE`) | `go clean -cache` | Low |
| `go-modules` | Every downloaded Go module (`GOMODCACHE`) | `go clean -modcache` | Medium |
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
- **poetry:** the location comes from `poetry config cache-dir` (which honors
  `POETRY_CACHE_DIR`). Each cache that `poetry cache list` shows is cleared by
  name, so this works with Poetry versions before 2.3, and one failed cache is
  reported without hiding the others. Poetry's `artifacts` folder (built
  wheels) is not cleared, because `poetry cache clear` does not touch it.
  Projects, lock files, and virtual environments are kept.
- **npm:** only `_cacache` is removed; the npx cache and logs next to it, and
  every `node_modules` folder, are kept.
- **pnpm:** the store comes from `pnpm store path`. Pruning keeps every package
  a project still uses, and pnpm has no preview, so Resik shows the store's
  size but no estimate; the measured result after cleaning is exact.
- **yarn:** only Yarn 1 (Classic) is supported. Yarn 2 and later keep a cache
  per project and are reported as not detected. The folder comes from
  `yarn cache dir`.
- **go-build, go-modules:** the folders come from `go env GOCACHE` and
  `go env GOMODCACHE`. The build cache only speeds up builds and tests. The
  module cache holds downloaded source, so builds download it again and fail
  while offline; hence Medium risk. `GOCACHE=off` is skipped.
- pnpm, Yarn, and Go run in your user profile folder, so a `package.json`,
  `.npmrc`, `.yarnrc`, or `go.mod` in the folder you start Resik from cannot
  change which cache is cleaned or make Go download another toolchain.
- **composer:** needs `composer.bat` (Composer-Setup) or a `composer.cmd` shim
  (Scoop) on PATH. The folders come from `composer global config cache-dir`
  (and `cache-files-dir`, `cache-repo-dir`, `cache-vcs-dir`); `global` makes
  Composer read and clear the same caches whatever the current folder is.
  Composer empties `cache-dir` entirely, so do not point `COMPOSER_CACHE_DIR`
  at a folder that holds anything else. `vendor` folders are not touched.
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

#### Compilation caches

PyTorch and Triton have no command to clear their caches, so Resik deletes the
contents of the cache folder itself, without following links, and keeps the
folder. The kernels are compiled again on the next run, which is slower once.

| ID | What it removes | Folder | Risk |
| --- | --- | --- | --- |
| `torch-inductor` | Kernels compiled by `torch.compile` (TorchInductor), including its Triton kernels | `%TEMP%\torchinductor_<user>` | Low |
| `triton` | GPU kernels compiled by Triton | `~\.triton\cache`, or `<TRITON_HOME>\.triton\cache` | Low |

- If `TORCHINDUCTOR_CACHE_DIR` or `TRITON_CACHE_DIR` moves a cache, Resik only
  reports its size, because a folder you chose could hold other files. Delete
  its contents yourself if it holds only the cache.
- `.triton\override` (kernels you replaced by hand) and `.triton\dump` are
  never touched.
- Kernels loaded by a running Python program are skipped and reported; close
  it and run Resik again.

#### Leftover app data (chosen one by one)

| ID | What it removes | How | Risk |
| --- | --- | --- | --- |
| `scoop-persist` | Folders in `<scoop>\persist` of apps that are no longer installed | Resik deletes each folder you confirm | High |
| `jetbrains-leftovers` | All data of JetBrains IDE versions, typically ones you uninstalled | Resik deletes each version you confirm | High |

Neither tool has a command to remove this data, so Resik deletes it itself. It
cannot be recovered, and `--all` and "select all" in the picker never choose
these targets; name them with `--only` or select them yourself. During cleanup
Resik asks about each folder or version separately. `--force` does not answer
these questions, and without a terminal nothing is removed.

When you uninstall a Scoop app without `--purge`, Scoop keeps its settings and
data in `<scoop>\persist\<app>` so a reinstall can reuse them. Scoop has no
command to remove that data once the app is gone:

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

Each JetBrains IDE version keeps `%LOCALAPPDATA%\JetBrains\<product><version>`
(caches, indexes, logs, plugins, and Local History) and
`%APPDATA%\JetBrains\<product><version>` (settings and plugins). Uninstalling
the IDE leaves both behind:

- `jetbrains-leftovers` offers every version folder, such as
  `PyCharm2024.1`, with both folders together. Resik cannot tell whether a
  version is still installed, because portable and Toolbox installs leave no
  record, so check the name before you answer `y`. Help \| Delete Leftover IDE
  Directories in a newer IDE does the same for old versions.
- Resik refuses to delete anything while a JetBrains IDE is running, and checks
  again after each answer.
- Everything for that version goes, including its settings and Local History
  (the IDE's record of your past edits). Other folders in `JetBrains`, such as
  Toolbox's, are not touched.
- The deletion never follows symbolic links or junctions, and stays inside the
  two `JetBrains` folders.

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

Not supported: WinGet has no cache-cleaning command, and Yarn 2 and later
keep their caches per project.

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
    Deletion.ps1          link-safe deletion (leftover data and Windows caches)
    Catalog.ps1           registered cleanup targets
  WindowsCleanup/         RecycleBin, ShaderCache, ThumbnailCache, WindowsUpdate
  DeveloperCleanup/       one file per tool: Uv, Pip, Poetry, Conda,
                          HuggingFace, PyTorch (torch-inductor, triton),
                          Npm, Pnpm, Yarn, Composer, Go,
                          Playwright, Scoop,
                          Chocolatey, NuGet, JetBrains (the analysis-only
                          jetbrains and jetbrains-leftovers), and the
                          analysis-only Gradle, Maven
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
