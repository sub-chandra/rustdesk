# RustDesk Tailnet for Windows

The Windows build uses the local Tailscale adapter for direct TCP sessions. The
home page reads devices and online status from the local Tailscale service.
The separate port test checks TCP reachability. A successful test does not
verify RustDesk authentication.

## GitHub and upstream

`origin` is the GitHub fork and `upstream` is the original RustDesk repository.
`custom/tailnet` starts from the official `1.5.3` tag. To adopt a newer stable
release, fetch tags, merge the chosen tag into the custom branch, and rebuild.

```powershell
git fetch upstream --tags
git switch custom/tailnet
git merge <official-release-tag>
git push origin custom/tailnet
```

The home-page update button compares the build with GitHub's latest stable
RustDesk release. It sends a version lookup to `api.github.com` when clicked
and installs nothing. RustDesk registration, relay, NAT probes, account
requests, LAN discovery, and automatic updates are disabled in this build.
The separate Tailscale service still uses its own control plane and may use
DERP when it cannot establish a direct path.

## Build and test

Follow the Windows x64 Flutter steps in
[the upstream build workflow](../.github/workflows/flutter-build.yml)
and [bridge generator workflow](../.github/workflows/bridge.yml).
Use the same Rust, Flutter, vcpkg, and bridge versions as the release that
the branch is based on. The Windows bundle can be built with
`python build.py --portable --flutter --skip-portable-pack --hwcodec --vram`.
Keep the complete Release directory together and rename its runner to
`RustDeskTailnet.exe` for side-by-side testing.

Run the import under the Windows account that uses RustDesk. It copies the
local configuration, password material, and available peer history into
`%APPDATA%\RustDeskTailnet\config`. Existing destination files are preserved.
Repeat on the controller to import that machine's own saved preferences and
history. Keep both configuration directories outside source control.

```powershell
.\scripts\import-tailnet-settings.ps1 -TestPort 21119
```

While the original controlled service is using 21118, test the custom build on
21119 from the controller using the host's Tailscale IP and the explicit port.
Successful login and restart tests should precede switching the production
listener. The Windows adapter must be named `Tailscale`.

To diagnose latency, check `tailscale status` during a session. A direct
Tailscale path avoids DERP latency. Keep the host TCP port limited to the
intended controller through tailnet grants. Use the existing RustDesk
authentication on top of Tailscale, and compare capture and codec settings
only after verifying the network path.
