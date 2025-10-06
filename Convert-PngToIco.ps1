# PowerShell script to convert PNG to high-resolution ICO
# This script converts IMPACT_icon.png to IMPACT_icon.ico with multiple resolutions

# Suppress PSScriptAnalyzer warnings for VS Code linting issues
# The script works correctly despite false positive linting errors
#Requires -Version 5.1

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

try {
    # Load the PNG image
    $pngPath = "IMPACT_icon.png"
    $icoPath = "IMPACT_icon.ico"
    
    if (-not (Test-Path $pngPath)) {
        Write-Host "Error: IMPACT_icon.png not found in current directory" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "Loading PNG image: $pngPath" -ForegroundColor Cyan
    $originalImage = [System.Drawing.Image]::FromFile((Resolve-Path $pngPath).Path)
    Write-Host "Original image size: $($originalImage.Width)x$($originalImage.Height)" -ForegroundColor Green
    
    # Create a memory stream for the ICO file
    $memoryStream = New-Object System.IO.MemoryStream
    
    # ICO file header (6 bytes)
    $memoryStream.WriteByte(0x00)  # Reserved
    $memoryStream.WriteByte(0x00)  # Reserved
    $memoryStream.WriteByte(0x01)  # Type (1 = ICO)
    $memoryStream.WriteByte(0x00)  # Type high byte
    
    # Define icon sizes to include (common Windows icon sizes)
    $sizes = @(16, 24, 32, 48, 64, 96, 128, 256)
    
    # Number of images
    $memoryStream.WriteByte($sizes.Count)
    $memoryStream.WriteByte(0x00)
    
    Write-Host "Creating ICO with $($sizes.Count) sizes: $($sizes -join ', ')" -ForegroundColor Cyan
    
    # Calculate directory entries and image data
    $imageDataOffset = 6 + ($sizes.Count * 16)  # Header + directory entries
    $imageData = @()
    
    foreach ($size in $sizes) {
        Write-Host "Processing size: ${size}x${size}" -ForegroundColor Yellow
        
        # Create resized bitmap
        $resizedBitmap = New-Object System.Drawing.Bitmap($size, $size)
        $graphics = [System.Drawing.Graphics]::FromImage($resizedBitmap)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        
        # Draw the resized image
        $graphics.DrawImage($originalImage, 0, 0, $size, $size)
        $graphics.Dispose()
        
        # Convert to PNG byte array for embedding in ICO
        $pngStream = New-Object System.IO.MemoryStream
        $resizedBitmap.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngBytes = $pngStream.ToArray()
        $pngStream.Dispose()
        $resizedBitmap.Dispose()
        
        # Store image data
        $imageData += @{
            Size = $size
            Data = $pngBytes
            Length = $pngBytes.Length
            Offset = $imageDataOffset
        }
        
        $imageDataOffset += $pngBytes.Length
    }
    
    # Write directory entries
    foreach ($img in $imageData) {
        $size = $img.Size
        # Directory entry (16 bytes)
        # Use ternary-like assignment for width/height bytes (0 means 256 in ICO format)
        if ($size -eq 256) {
            $widthByte = 0
            $heightByte = 0
        } else {
            $widthByte = $size
            $heightByte = $size
        }
        
        $memoryStream.WriteByte($widthByte)   # Width (0 = 256)
        $memoryStream.WriteByte($heightByte)  # Height (0 = 256)
        $memoryStream.WriteByte(0x00)  # Color count (0 = no palette)
        $memoryStream.WriteByte(0x00)  # Reserved
        $memoryStream.WriteByte(0x01)  # Planes (low byte)
        $memoryStream.WriteByte(0x00)  # Planes (high byte)
        $memoryStream.WriteByte(0x20)  # Bits per pixel (low byte) - 32 bit
        $memoryStream.WriteByte(0x00)  # Bits per pixel (high byte)
        
        # Image size (4 bytes)
        $sizeBytes = [System.BitConverter]::GetBytes([uint32]$img.Length)
        $memoryStream.Write($sizeBytes, 0, 4)
        
        # Image offset (4 bytes)
        $offsetBytes = [System.BitConverter]::GetBytes([uint32]$img.Offset)
        $memoryStream.Write($offsetBytes, 0, 4)
    }
    
    # Write image data
    foreach ($img in $imageData) {
        $memoryStream.Write($img.Data, 0, $img.Data.Length)
    }
    
    # Save the ICO file
    $icoBytes = $memoryStream.ToArray()
    [System.IO.File]::WriteAllBytes((Join-Path $PWD $icoPath), $icoBytes)
    $memoryStream.Dispose()
    $originalImage.Dispose()
    
    Write-Host "Successfully created: $icoPath" -ForegroundColor Green
    Write-Host "ICO file size: $([math]::Round($icoBytes.Length / 1KB, 2)) KB" -ForegroundColor Green
    Write-Host "Contains $($sizes.Count) icon sizes for high-resolution display support" -ForegroundColor Green
    
} catch {
    Write-Host "Error converting PNG to ICO: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}