# IMPACT Docker GUI v2 – User Guide

## What this tool does
A Windows GUI that builds and runs the IMPACT RStudio Docker container locally or on a remote workstation, handling SSH keys, Docker contexts, and mounts for your project data.

## Quick start (happy path)
1) Run the script: double-click IMPACT_Docker_GUI_v2.ps1 (or use V2\Compile-IMPACT-v2.bat then run the EXE).
2) Enter username and password.
3) Let it create/show your SSH key; add the public key to GitHub if you need repo access.
4) Choose Local or Remote (enter remote IP if remote).
5) Pick your repo (Local: folder picker; Remote: list from the workstation).
6) In Container Manager, review options and click Start Container.
7) Open the shown URL; login: user rstudio, password you entered. Click Stop when finished.

## Step-by-step workflow
1) **Launch**: start IMPACT_Docker_GUI_v2.ps1 (PowerShell 7 recommended). The console shows progress messages.
2) **Credentials**: enter username (spaces removed, lowercased) and password (used for RStudio login and container env).
3) **SSH key setup**: if no key exists at ~/.ssh/id_ed25519_<username>, one is created. Copy the shown public key to GitHub (Settings → SSH and GPG keys) if you need Git over SSH.
4) **Choose location**:
   - Local: for testing on your machine.
   - Remote: for heavy runs; provide the workstation IP (default filled).
   - Optional: enable Debug to see verbose console logs.
5) **Local prep** (if local): select your repo folder. Tool checks/starts Docker Desktop and sets Docker context "local". It proceeds even if the folder is not a Git repo (with a warning).
6) **Remote prep** (if remote): tool authorizes your key on the workstation (password bootstrap via plink if key auth not yet allowed), copies key/known_hosts, lists repos under /home/php-workstation/Schreibtisch/Repositories for selection, and configures Docker context or direct SSH fallback.
7) **Status detection**: tool scans Docker for existing containers/ports and resumes info if your container is already running (shows URL/login).
8) **Container Manager**:
   - Shows status, URL, login (rstudio / your password), repo, container name, location.
   - Options before Start:
     - Use Docker Volumes (recommended for remote or to avoid bind issues). Data syncs back on Stop.
     - Rebuild image (forces docker build).
     - High computational demand (remote only): adds CPU/RAM limits.
     - Port override (remote only): choose a free port; local always 8787.
     - Custom Params: extra docker run args (space-separated).
     - sim_design.yaml path: relative paths resolve against repo root.
   - Start validates ports/paths, builds image if needed, prepares volumes/mounts, starts the container, and shows connection info.
   - Stop halts the container; if volumes were used, data is rsynced back to host folders and volumes removed. Then an optional Git commit/push dialog may appear if changes are detected.

## Connecting to RStudio
- URL shown in the dialog: local → http://localhost:port, remote → http://<remote-ip>:port.
- Login: user rstudio, password = the one you entered in the credential dialog.

## Options explained
- **Use Docker Volumes**: creates per-user volumes for outputs and synthpop; prepopulates from your host folders and syncs back on Stop. Safer for remote runs.
- **Rebuild image**: forces a fresh docker build even if the image exists.
- **High computational demand**: remote only; applies --cpus 32 -m 384g.
- **Port override**: remote only; must not conflict with other running containers.
- **Custom Params**: additional docker run flags (advanced users).
- **sim_design.yaml**: used to locate output_dir and synthpop_dir; must exist and contain those keys.

## Troubleshooting
- Docker not running: start Docker Desktop; the tool tries to start it but may time out.
- Missing docker_setup (local): ensure docker_setup and Dockerfile.IMPACTncdGER are in the repo root.
- Port already in use: pick another port (remote) or stop conflicting containers. Local is fixed to 8787.
- SSH key issues (remote): rerun key setup; ensure ~/.ssh/id_ed25519_<user> and known_hosts exist locally. If first-time connect fails, plink bootstrap will prompt for the remote password.
- Remote Docker context fails: tool falls back to DOCKER_HOST over SSH; check network/firewall and SSH access if both fail.
- Build fails: check console output; the tool retries with a prerequisite Dockerfile and then retries the main build.
- YAML errors: verify sim_design.yaml path and that output_dir and synthpop_dir resolve to existing directories.
- Volume sync issues: ensure rsync-alpine image builds; verify output/synthpop folders are writable and exist. If data is missing, check console logs for rsync or volume removal errors.
- Git dialog on stop: appears when repo has changes; enter a message to commit/push, or cancel to skip.
- Dialogs off-screen: move the mouse to the desired monitor before the dialog opens (forms center on cursor monitor).

## Tips
- Use Debug mode during setup to see detailed progress in the console.
- Keep your username consistent; it is used for container naming and per-user volumes.
- Remote metadata is cleaned when stopping; if you manually remove containers, stale metadata is handled gracefully on the next run.

## How to build the EXE (v2)
- Interactive compile: run V2/Compile-IMPACT-v2.bat.
- Silent compile: run V2/Quick-Compile-v2.bat.
- Output: IMPACT_v2.exe in the V2 folder.
