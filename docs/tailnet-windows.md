# RustDesk Tailnet for Windows

The Windows build uses the local Tailscale adapter for direct TCP sessions. The
home page reads devices and online status from the local Tailscale service.
The port test checks TCP reachability. Establish a desktop session to verify
RustDesk authentication.

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

The update button under Settings → General compares the build with GitHub's latest stable
RustDesk release. It sends a version lookup to `api.github.com` when clicked
and displays the release version. RustDesk registration, relay, NAT probes, account
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
`%APPDATA%\RustDeskTailnet\config`. The import fills missing destination files.
Repeat on the controller to import that machine's own saved preferences and
history. Keep both configuration directories outside source control.

```powershell
.\scripts\import-tailnet-settings.ps1 -TestPort 21119
```

While the original controlled service is using 21118, test the custom build on
21119 from the controller using the host's Tailscale IP and the explicit port.
The Windows background service starts with Windows and accepts incoming
connections before sign-in, subject to the configured RustDesk authentication.
Successful login and restart tests should precede switching the production
listener. The Windows adapter must be named `Tailscale`.

To diagnose latency, check `tailscale status` during a session. A direct
Tailscale path avoids DERP latency. Keep the host TCP port limited to the
intended controller through tailnet grants. Use the existing RustDesk
authentication on top of Tailscale, and compare capture and codec settings
only after verifying the network path.

## Tray, password settings, and custom packages

Closing the main window hides it. Starting the app recreates the Windows
tray icon when needed. The service menu controls incoming desktop access.

The Windows desktop receiver starts when its backend starts. Launching a
second copy from a build folder opens the installed application when present.
Use Settings → Security to choose and set the RustDesk authentication
method. The installed app and its Windows service share that setting over
the authenticated local Windows IPC channel.

Build Flutter with the publisher's
Tailscale IP in `TAILNET_UPDATE_PUBLISHER` and the publisher's absolute
`releases/RustDeskTailnet-windows-x64.zip` path in `TAILNET_RELEASE_ZIP`.
Pass the last two values through `--dart-define`. Keep device addresses in
local build parameters.

After a Windows build, run `scripts/publish-tailnet.ps1` from the project.
It writes `releases/RustDeskTailnet-windows-x64.zip` in the repository root.
The configured publisher serves that file on Tailnet TCP port 21120 while
RustDesk Tailnet runs, including when its window is hidden. On controllers,
Settings → General → Update → Download custom build uses the configured
publisher and opens a save dialog. Installing the downloaded build is a
separate step.

For a connection stuck at connecting, verify which executable listens on
the direct-access port on the controlled PC. A reachable TCP port and a
working Tailscale ping establish network connectivity. The controlled
RustDesk process still needs to send its handshake before authentication.
