# IMPACT.exe Compilation Guide

This folder contains all the necessary files and scripts to compile the PowerShell GUI script into a standalone executable.

## Files Overview

### Main Files
- `access_rstudio_gui.ps1` - Main PowerShell script with Docker container management functionality
- `IMPACT.exe` - Compiled executable (generated)

### Icon Files
- `IMPACT_icon.png` - Original PNG icon (1024x1024)
- `IMPACT_icon.ico` - High-resolution ICO icon with multiple sizes (16x16 to 256x256)

### Compilation Scripts
- `Compile-IMPACT.ps1` - PowerShell compilation script with full options and verbose output
- `Compile-IMPACT.bat` - Interactive batch file with detailed output and error handling
- `Quick-Compile.bat` - Silent batch file for fast compilation with minimal output
- `Convert-PngToIco.ps1` - Utility to convert PNG to high-resolution ICO

## Quick Compilation

### Method 1: Quick Batch File (Fastest)
Double-click `Quick-Compile.bat` for silent compilation with minimal output.

### Method 2: Interactive Batch File (Detailed)
Double-click `Compile-IMPACT.bat` for full compilation details and error messages.

### Method 3: PowerShell Script (Advanced)
```powershell
.\Compile-IMPACT.ps1 -Force
```

### Method 4: Manual ps2exe (Expert)
```powershell
Invoke-PS2EXE -InputFile .\access_rstudio_gui.ps1 -OutputFile .\IMPACT.exe -iconFile .\IMPACT_icon.ico
```

## Icon Management

### Convert PNG to ICO
If you update the PNG icon, run:
```powershell
.\Convert-PngToIco.ps1
```

This creates a high-resolution ICO file with these sizes:
- 16x16, 24x24, 32x32, 48x48, 64x64, 96x96, 128x128, 256x256

## Compilation Features

The compiled executable includes:
- ✅ **Custom High-Resolution Icon** - Professional appearance in Windows
- ✅ **Administrator Privilege Elevation** - Automatic UAC prompt handling
- ✅ **Windows Forms GUI** - Rich dialog interfaces instead of console prompts
- ✅ **PowerShell Version Detection** - Optimal PowerShell version handling
- ✅ **Docker Container Management** - Full local and remote container support
- ✅ **SSH Connection Handling** - Secure remote host connectivity
- ✅ **Git Repository Integration** - Automatic change detection and commit prompts

## Usage

### Running the Executable
1. **Right-click** `IMPACT.exe` and select **"Run as Administrator"**
2. Or **double-click** to start with automatic elevation prompt

### First Run Behavior
1. Shows PowerShell version notice (if using Windows PowerShell 5.1)
2. Requests administrator elevation via UAC prompt
3. Proceeds to username/password dialog for container access

## Troubleshooting

### Icon Not Showing
- Ensure `IMPACT_icon.ico` exists in the same folder as the script
- Recompile using `Compile-IMPACT.ps1 -Force`

### Compilation Errors
- Check that ps2exe module is installed: `Install-Module ps2exe -Scope CurrentUser`
- Ensure all files are in the same directory
- Run PowerShell as Administrator if needed

### Runtime Issues
- The executable requires Administrator privileges for Docker operations
- Windows may show security warnings for unsigned executables (normal behavior)

## Requirements

- **PowerShell 5.1+** (Windows PowerShell or PowerShell 7)
- **ps2exe Module** - Automatically installed by compilation script
- **Windows 10/11** - For optimal Windows Forms support
- **Docker Desktop** - For container management functionality

## Notes

- The executable is self-contained and doesn't require PowerShell to be installed on target machines
- All ps2exe compatibility fixes are included (Read-Host replacement, elevation handling, etc.)
- The icon contains multiple resolutions for crisp display on different screen densities
- Environment variable flags prevent double PowerShell version prompts during elevation