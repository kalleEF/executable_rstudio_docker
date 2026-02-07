# IMPACT Docker GUI v2 – Technical Documentation

## Purpose
Engineering reference for IMPACT_Docker_GUI_v2.ps1: architecture, functions, data model, and end-to-end workflow for local and remote container orchestration.

## Architecture Overview
- PowerShell 7+ WinForms UI orchestrating Docker locally or via SSH.
- Single entrypoint: Invoke-ImpactGui (end of script).
- State passed through a shared PSCustomObject created by New-SessionState.
- Docker access via contexts (preferred) or direct DOCKER_HOST/DOCKER_SSH_OPTS fallback.
- Remote metadata stored in /tmp/impactncd/<container>.json to resume sessions.
- Optional Git integration for commit/push on stop.

## Data Model (New-SessionState)
- Identity: UserName, Password.
- Remote: RemoteHost, RemoteHostIp, RemoteUser (php-workstation), RemoteRepoBase.
- Selection: ContainerLocation (LOCAL or REMOTE@ip), SelectedRepo, ContainerName.
- Paths: LocalRepo, RemoteRepo, OutputDir, SynthpopDir, SshPrivate, SshPublic.
- Flags: Debug, UseDirectSsh, UseVolumes, Rebuild, HighComputeDemand, PS7Requested.
- Ports: Requested, Assigned, Used.
- Metadata: LocalDockerContext, RemoteDockerContext, ExistingContainers, ContainerRunning, Recovered (Password, Port, UseVolumes), ActiveRepoPath, ActivePort, ActiveUseVolumes, ActiveIsRemote, GitBaseline, VolumeOutput, VolumeSynthpop.

## Key Functions
- Logging: Write-Log (Info/Warn/Error/Debug gated by GlobalDebugFlag).
- Host helpers: Get-RemoteHostString, Set-DockerSSHEnvironment, Get-DockerContextArgs, Convert-PathToDockerFormat, Test-AndCreateDirectory, Get-YamlPathValue.
- SSH/metadata: Test-RemoteSSHKeyFiles, Write-RemoteContainerMetadata, Read-RemoteContainerMetadata, Remove-RemoteContainerMetadata.
- Docker inspect: Get-ContainerRuntimeInfo (PASSWORD env and 8787 binding).
- Git: Get-GitRepositoryState, Show-GitCommitDialog, Invoke-GitChangeDetection (converts GitHub https remote to SSH; supports remote agent fallback).
- UI theming/layout: Initialize-ThemePalette, Apply-ThemeToForm, Style-Label/TextBox/CheckBox/Button/InfoBox, Set-FormCenterOnCurrentScreen.
- UI steps: Show-CredentialDialog, Ensure-GitKeySetup, Select-Location, Ensure-RemotePreparation, Ensure-LocalPreparation, Show-ContainerManager.
- Coordinator: Invoke-ImpactGui (runs full sequence).

## Detailed Workflow (step-by-step)
1) Invoke-ImpactGui
   - Creates state (New-SessionState).
   - Calls Ensure-Prerequisites; then Show-CredentialDialog; Ensure-GitKeySetup; Select-Location.
   - Branches: Ensure-RemotePreparation or Ensure-LocalPreparation.
   - Calls Get-ContainerStatus and then Show-ContainerManager.

2) Ensure-Prerequisites
   - Loads WinForms/Drawing, enables visual styles.
   - Recommends PowerShell 7 restart if PS < 6 (no auto-elevate).
   - Logs admin status; sets console colors/title.

3) Show-CredentialDialog
   - Captures username/password; username normalized (remove spaces, lowercase).
   - Stores in state; aborts on cancel/empty.

4) Ensure-GitKeySetup
   - Ensures ~/.ssh/id_ed25519_<user> exists; generates if missing.
   - Stores paths in state, captures public key into Metadata.PublicKey.
   - Displays key in themed dialog; copies to clipboard best-effort; starts ssh-agent if available.

5) Select-Location
   - UI to choose Local or Remote; sets Debug flag (GlobalDebugFlag) and remote IP.
   - Sets ContainerLocation, RemoteHost/Ip, RemoteRepoBase default.

6) Remote branch: Ensure-RemotePreparation
   - Validates local key files.
   - Probes key auth; if missing, uploads public key and authorized_keys via SSH; password bootstrap via plink if needed.
   - Copies private key and known_hosts to remote ~/.ssh (base64 pipe).
   - Lists repos under RemoteRepoBase; user selects; sets SelectedRepo, Paths.RemoteRepo, ContainerName.
   - Creates Docker context remote-<ip> (ssh://user@ip); uses docker context use; falls back to DOCKER_HOST direct SSH if context activation fails.

7) Local branch: Ensure-LocalPreparation
   - FolderBrowserDialog to pick repo root; warns if no .git.
   - Checks Docker availability; attempts to start Docker Desktop/service if not running; waits with polling.
   - Creates/uses Docker context "local" pointing to npipe:// or unix:// socket; verifies connection.
   - Sets Paths.LocalRepo, SelectedRepo, ContainerName, Metadata.LocalDockerContext.

8) Get-ContainerStatus
   - Sets docker context args; scans running containers/ports; fills Ports.Used.
   - Lists existing containers for user pattern _<user>; stores Metadata.ExistingContainers.
   - Detects running target container; recovers password/port from remote metadata or docker inspect.

9) Show-ContainerManager (main UI)
   - Displays status, URL, login, repo, container, location.
   - Controls: Start, Stop; options: Use Docker Volumes, Rebuild image, High computational demand (remote only), Port override (disabled locally), Custom Params, sim_design.yaml path.
   - On Start:
     - Validates port availability, SSH presence (remote), other running containers warning.
     - Resolves repo root and docker_setup presence (local check).
     - Resolves sim_design.yaml (relative allowed); verifies existence locally.
     - Builds image if missing or rebuild requested; uses Dockerfile.IMPACTncdGER; prerequisite fallback Dockerfile.prerequisite.IMPACTncdGER; supports remote build via ssh; streams via Start-Process.
     - Captures Git baseline best-effort.
     - Resolves output_dir/synthpop_dir from YAML (Get-YamlPathValue) and verifies with Test-AndCreateDirectory.
     - Mounts: repo bind to /host-repo and /home/rstudio/<repo>; output/synthpop bind; or volume mode creating per-user volumes, pre-populating via rsync-alpine helper, setting ownership.
     - High compute (remote only): adds --cpus 32 -m 384g.
     - Mounts SSH key and known_hosts; sets GIT_SSH_COMMAND env.
     - Runs container detached, --rm, publishes port; stores Active* metadata; writes remote metadata (password/port/useVolumes).
   - On Stop:
     - Stops container via docker stop.
     - If volume mode active, rsyncs volume contents back to host output/synthpop, then removes volumes.
     - Clears ContainerRunning, removes remote metadata; updates UI.
     - Triggers Invoke-GitChangeDetection on active repo (local or remote) to optionally commit/push.

10) Invoke-GitChangeDetection
    - Reads git status; if changes, shows commit dialog; commits and optional push.
    - Remote push: tries ssh-agent path or direct GIT_SSH_COMMAND with mounted key.

## Docker/Path Details
- Image: lowercased SelectedRepo.
- Container name: <repo>_<user>.
- Default port: 8787; remote override allowed if free; local forced to 8787.
- Mounts avoid duplicate targets; POSIX-style absolute paths rejected in local mode.
- Volume names sanitized to alnum/underscore.

## Error Handling and Guards
- Early returns on validation failures at each stage.
- Remote metadata read/write best-effort; absence handled.
- Debug logging controllable at location selection.
- StrictMode enabled; recovered metadata pre-seeded to avoid missing-member errors.

## Extension Points
- Logging can be redirected to file by extending Write-Log.
- Theming centralized in Initialize-ThemePalette and Style-* helpers.
- Build pipeline can swap Dockerfile paths/args where constructed in Show-ContainerManager.
- RemoteRepoBase defaults to /home/<remoteUser>/Schreibtisch/Repositories; override via state before Ensure-RemotePreparation if needed.
