# Releasing Resik

Resik is released as a zip archive attached to a GitHub Release and installed
through the `personal` Scoop bucket
(<https://github.com/rendicahya/scoop-bucket>). That bucket holds only the
manifest; this repository owns the source, release archive, and release notes.

## 1. Prepare the release on `main`

1. Set the version in `Get-ResikVersion` (`src/Resik/Core/Cli.ps1`) to a
   plain `MAJOR.MINOR.PATCH` version. The build script refuses pre-release
   versions such as `0.2.0-dev`.
2. Merge the change to `main` through a pull request with CI passing.

## 2. Tag and build

From an up-to-date, clean `main`:

```powershell
git switch main
git pull --ff-only
git tag -a v0.1.0 -m "Resik 0.1.0"
.\tools\Build-Release.ps1
```

The build script writes `dist/resik-<version>.zip` (ignored by Git) containing
the contents of `src/Resik` (`Resik.ps1` and every source subfolder),
`LICENSE`, and `README.md`, and prints the archive's SHA-256. Zip archives embed timestamps, so rebuilding
produces a different hash; always use the hash of the file you upload.

## 3. Publish the GitHub Release

```powershell
git push origin v0.1.0
gh release create v0.1.0 dist\resik-0.1.0.zip --title "Resik 0.1.0" --notes-file <notes.md>
```

Then verify the published asset rather than the local file:

```powershell
gh release download v0.1.0 --pattern 'resik-0.1.0.zip' --dir <empty temp dir>
Get-FileHash <empty temp dir>\resik-0.1.0.zip -Algorithm SHA256
```

## 4. Update the Scoop manifest

In the bucket repository, add or update `bucket/resik.json` on a feature
branch with the new `version`, `url`, and the verified `hash`. Test it before
opening a pull request:

```powershell
scoop install .\bucket\resik.json
resik --version
resik --dry-run --all
scoop uninstall resik
```

The manifest declares `checkver` and `autoupdate`, so Scoop's
`checkver.ps1 -Update` tooling can propose later version bumps; still verify
the resulting hash against the published asset.
