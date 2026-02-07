# IMPACT Docker GUI v2 – Technical and User Documentation

## Purpose and Scope
- Provides a WinForms front-end to build and run the IMPACT RStudio Docker container locally or on a remote workstation.
- Automates SSH key prep, Docker context selection, repo selection, volume setup, container start/stop, and optional Git commit prompts.
- Script location: V2/IMPACT_Docker_GUI_v2.ps1.

## High-Level Workflow
1) **Prerequisites** (`Ensure-Prerequisites`): load WinForms/Drawing, recommend PowerShell 7, set console styling, check elevation (no auto-elevate), enable visual styles.
2) **Credential capture** (`Show-CredentialDialog`): username/password entry; username normalized (remove spaces, lowercase). Stored in session state.
3) **SSH key setup** (`Ensure-GitKeySetup`): ensure `~/.ssh/id_ed25519_<user>` exists; generate if missing; display and copy public key; start ssh-agent when available.
4) **Location selection** (`Select-Location`): choose Local or Remote; optional debug flag; remote IP input (default 10.162.194.34). Sets `ContainerLocation` and remote host strings.
5) **Remote prep** (`Ensure-RemotePreparation`):
   - Validate keys exist; ensure authorized_keys on remote via ssh/plink bootstrap; copy private key and known_hosts to remote.
   - Discover repos under `/home/<remoteUser>/Schreibtisch/Repositories`; user picks one.
   - Configure Docker context `remote-<ip>` or fallback to DOCKER_HOST direct SSH.
   - Set `ContainerName` as `<repo>_<user>`.
6) **Local prep** (`Ensure-LocalPreparation`):
   - Folder browser for repo root; warns if not a Git repo.
   - Check/start Docker Desktop; create/use `local` Docker context pointing to pipe/socket.
7) **Container status detection** (`Get-ContainerStatus`):
   - Scan in-use ports, list existing containers for user, detect if target container already running.
   - Recover password/port from remote metadata or docker inspect.
8) **Container management UI** (`Show-ContainerManager`):
   - Shows status, URL, login, repo, container name, location.
   - Actions: Start, Stop; options: volumes, rebuild, high-compute (remote only), port override (disabled locally), custom params, sim_design.yaml path.
   - On start: build image if missing/rebuild; resolve YAML paths; ensure output/synthpop dirs; handle volumes (create, chown, prepopulate; rsync-alpine image check); bind mounts; start container with SSH mounts; write remote metadata.
   - On stop: stop container; if volumes used, rsync volumes back then remove volumes; optional Git change detection/commit dialog.
9) **Coordinator** (`Invoke-ImpactGui`): orchestrates the above in order; exits early on any failure/cancel.

## Core Data Model (Session State)
Created by `New-SessionState` and passed through all functions:
- Identity: `UserName`, `Password`.
- Remote info: `RemoteHost`, `RemoteHostIp`, `RemoteUser` (default php-workstation), `RemoteRepoBase`.
- Selection: `ContainerLocation` (LOCAL or REMOTE@ip), `SelectedRepo`, `ContainerName`.
- Paths: `LocalRepo`, `RemoteRepo`, `OutputDir`, `SynthpopDir`, `SshPrivate`, `SshPublic`.
- Flags: `Debug`, `UseDirectSsh`, `UseVolumes`, `Rebuild`, `HighComputeDemand`, `PS7Requested`.
- Ports: `Requested`, `Assigned`, `Used`.
- Metadata: `LocalDockerContext`, `RemoteDockerContext`, `ExistingContainers`, `ContainerRunning`, `Recovered` (Password/Port/UseVolumes), `Active*` session fields, `GitBaseline`, volume names.

## Function Reference (key behaviors)
- `Write-Log`: leveled console logging (Info/Warn/Error/Debug), gated by GlobalDebugFlag.
- `Get-RemoteHostString`: returns host/IP string.
- `Set-DockerSSHEnvironment`: sets DOCKER_SSH_OPTS; optionally DOCKER_HOST for direct SSH.
- `Get-DockerContextArgs`: builds docker CLI context args for local/remote/direct modes.
- `Convert-PathToDockerFormat`: converts Windows path to /drive/path Docker style.
- `Test-RemoteSSHKeyFiles`: quick remote presence check for key + known_hosts.
- `Write/Read/Remove-RemoteContainerMetadata`: store/retrieve/clean `/tmp/impactncd/<container>.json` with password/port/volumes.
- `Get-ContainerRuntimeInfo`: docker inspect env/ports for PASSWORD and 8787 binding.
- `Get-YamlPathValue`: simple `key: value` resolver (local or SSH), joins relative paths to base dir, normalizes slashes.
- `Test-AndCreateDirectory`: verifies directories (local or remote); blocks POSIX-style paths in local mode.
- `Get-GitRepositoryState`: git status/branch/remote locally or over SSH.
- `Show-GitCommitDialog`: modal commit/push dialog with changes summary.
- `Invoke-GitChangeDetection`: optional commit/push (converts GitHub https remote to SSH; handles remote agent fallback).
- `Set-FormCenterOnCurrentScreen`: centers forms on monitor with cursor via Win32.
- Theme helpers: `Initialize-ThemePalette`, `Apply-ThemeToForm`, `Style-*` for consistent UI colors/fonts.
- UI steps: `Show-CredentialDialog`, `Select-Location`, `Ensure-GitKeySetup` (dialogs), `Ensure-RemotePreparation`, `Ensure-LocalPreparation`, `Show-ContainerManager`.
- `Ensure-Prerequisites`: load assemblies, recommend PS7, set console appearance.
- `Invoke-ImpactGui`: main entrypoint; runs full flow.

## Docker and Container Details
- Image name: lowercased repo name; builds via `docker_setup/Dockerfile.IMPACTncdGER` (prereq fallback).
- Container name: `<repo>_<user>`.
- Ports: default 8787; remote override allowed if free; local forced to 8787; conflict check against running containers.
- Mounts:
  - Bind: repo to `/host-repo` and `/home/rstudio/<repo>`.
  - Bind outputs/synthpop (no duplicate target) when volumes disabled.
  - Volume mode: creates per-user volumes `impactncd_germany_output_<user>`, `impactncd_germany_synthpop_<user>`; prepopulates from host; syncs back on stop using rsync-alpine helper, then removes volumes.
- SSH in container: mounts key and known_hosts, sets `GIT_SSH_COMMAND` env.
- High compute (remote only): `--cpus 32 -m 384g` when enabled.
- Remote metadata: password/port/volumes saved to `/tmp/impactncd/...` for resume.

## User Guide
### Prerequisites
- Windows with PowerShell 7 recommended; WinForms available.
- Docker Desktop installed and running (script will try to start it if not running).
- Remote mode: reachable workstation, SSH access for `php-workstation@<ip>`, rsync permitted via Docker.
- Repo contains `docker_setup` and `docker_setup/Dockerfile.IMPACTncdGER`.

### Running the app
1) Launch the script (double-click or `pwsh -ExecutionPolicy Bypass -File .\IMPACT_Docker_GUI_v2.ps1`).
2) Enter username/password (username normalized; used for SSH key naming and container name).
3) If prompted, allow SSH key generation; add the displayed public key to GitHub if needed.
4) Choose Local or Remote:
   - **Local**: pick your repo folder; ensure Docker Desktop is running.
   - **Remote**: enter IP; script authorizes key on remote and lets you choose a repo.
5) Container Manager shows current status. Set options if needed (volumes, rebuild, high compute for remote, custom params, YAML path). Start container.
6) Copy the shown URL; login is `rstudio` with the password you entered. On stop, volumes sync back (if used) and optional git commit dialog may appear.

### Options and Fields
- **Use Docker Volumes**: safer sync; creates per-user volumes and syncs on stop. Recommended for remote to avoid mount issues.
- **Rebuild image**: forces image rebuild.
- **High computational demand**: adds CPU/RAM limits (remote only).
- **Port Override**: remote only; must not conflict with detected ports. Local is fixed to 8787.
- **Custom Params**: extra docker run args (space-separated).
- **sim_design.yaml**: path to YAML; relative paths resolved against repo root.

## Troubleshooting
- **Docker not available/running**: Ensure Docker Desktop is installed and started. Script attempts auto-start; if it times out, start manually and retry.
- **Missing docker_setup**: For local runs, ensure `docker_setup` exists under the repo root. Without it, container start is blocked.
- **Port already in use**: Pick another port (remote) or stop conflicting containers. Local always uses 8787; stop other 8787 containers.
- **SSH key/known_hosts missing (remote)**: Re-run key setup (step 2) or ensure `~/.ssh/id_ed25519_<user>` and known_hosts exist locally; remote prep copies them over.
- **Remote auth fails on first connect**: If key auth not yet allowed, plink password bootstrap prompts; ensure plink.exe exists (PuTTY). Otherwise add your public key to authorized_keys manually.
- **Docker context create/use fails (remote)**: Script falls back to DOCKER_HOST direct SSH. If both fail, check network/firewall and SSH access to the Docker host.
- **Build failures**: Check console output. The script retries with prerequisite Dockerfile if the main build fails, then retries the main build. Verify Dockerfiles and paths.
- **YAML path errors**: Ensure `sim_design.yaml` path is correct and contains `output_dir` and `synthpop_dir`; these paths must exist or validation fails.
- **Volume sync errors**: Volume mode uses rsync-alpine; ensure image builds. After stop, if data missing, check that volumes were created and rsynced back; verify output/synthpop directories exist and are writable.
- **Git commit dialog on stop**: Appears when changes detected in active repo; enter a message to commit/push, or cancel to skip.
- **UI dialogs off-screen**: Forms center on the monitor with your cursor; move cursor to target monitor before dialogs open.

## Operational Notes
- Logging verbosity controlled by Debug checkbox during location selection; Debug also sets GlobalDebugFlag to emit Debug logs.
- Remote metadata is cleaned on stop; if you manually remove containers, metadata may become stale (script handles missing metadata gracefully).
- Local mode rejects POSIX-style absolute paths for mounts to avoid accidental remote paths.
- Container auto-removal uses `--rm`; stopping removes container. Volumes removed after sync when volume mode enabled.

## Quick Reference (Commands)
- Run GUI: `pwsh -ExecutionPolicy Bypass -File .\V2\IMPACT_Docker_GUI_v2.ps1`
- Build/compile to EXE (v2): use `V2\Compile-IMPACT-v2.bat` or `V2\Quick-Compile-v2.bat`.
