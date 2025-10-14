<#
.SYNOPSIS
    Converts Markdown files to HTML format.

.DESCRIPTION
    This script converts Markdown (.md) files to standalone HTML files with styling.
    The output includes syntax highlighting, table formatting, and a professional appearance.

.PARAMETER InputFile
    Path to the Markdown file to convert. Use "*" to convert all .md files in the current directory.

.PARAMETER OutputFile
    (Optional) Path for the output HTML file. If not specified, uses the same name as input with .html extension.

.PARAMETER Theme
    (Optional) Visual theme: 'light' (default) or 'dark'.

.EXAMPLE
    .\Convert-MarkdownToHtml.ps1 -InputFile "USER-MANUAL.md"
    
.EXAMPLE
    .\Convert-MarkdownToHtml.ps1 -InputFile "*" -Theme dark
    
.EXAMPLE
    .\Convert-MarkdownToHtml.ps1 -InputFile "USER-MANUAL.md" -OutputFile "manual.html"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$InputFile,
    
    [Parameter(Mandatory = $false)]
    [string]$OutputFile,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet('light', 'dark')]
    [string]$Theme = 'light'
)

function Convert-MarkdownFile {
    param(
        [string]$MdFile,
        [string]$HtmlFile,
        [string]$Theme
    )
    
    Write-Host "Converting: $MdFile" -ForegroundColor Cyan
    
    # Read markdown content
    $mdContent = Get-Content $MdFile -Raw -Encoding UTF8
    
    # Escape backticks and dollar signs for JavaScript
    $mdContentEscaped = $mdContent -replace '\\', '\\' -replace '`', '\`' -replace '\$', '\$'
    
    # Determine theme colors
    if ($Theme -eq 'dark') {
        $bgColor = '#1e1e1e'
        $textColor = '#d4d4d4'
        $codeColor = '#2d2d2d'
        $borderColor = '#404040'
        $linkColor = '#569cd6'
        $headingColor = '#4ec9b0'
    } else {
        $bgColor = '#ffffff'
        $textColor = '#333333'
        $codeColor = '#f6f8fa'
        $borderColor = '#d0d7de'
        $linkColor = '#0969da'
        $headingColor = '#1f2328'
    }
    
    # Create HTML with embedded Markdown processor
    $htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$(Split-Path $MdFile -Leaf)</title>
    <script src="https://cdn.jsdelivr.net/npm/marked@11.0.0/marked.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/dompurify@3.0.6/dist/purify.min.js"></script>
    <style>
        * {
            box-sizing: border-box;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
            line-height: 1.6;
            max-width: 900px;
            margin: 0 auto;
            padding: 40px 20px;
            background-color: $bgColor;
            color: $textColor;
        }
        
        h1, h2, h3, h4, h5, h6 {
            margin-top: 24px;
            margin-bottom: 16px;
            font-weight: 600;
            line-height: 1.25;
            color: $headingColor;
        }
        
        h1 {
            font-size: 2em;
            border-bottom: 1px solid $borderColor;
            padding-bottom: 0.3em;
        }
        
        h2 {
            font-size: 1.5em;
            border-bottom: 1px solid $borderColor;
            padding-bottom: 0.3em;
        }
        
        h3 {
            font-size: 1.25em;
        }
        
        a {
            color: $linkColor;
            text-decoration: none;
        }
        
        a:hover {
            text-decoration: underline;
        }
        
        code {
            background-color: $codeColor;
            padding: 0.2em 0.4em;
            border-radius: 6px;
            font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
            font-size: 85%;
        }
        
        pre {
            background-color: $codeColor;
            padding: 16px;
            border-radius: 6px;
            overflow-x: auto;
            border: 1px solid $borderColor;
        }
        
        pre code {
            background-color: transparent;
            padding: 0;
            border-radius: 0;
            font-size: 100%;
        }
        
        blockquote {
            border-left: 4px solid $borderColor;
            padding-left: 16px;
            margin-left: 0;
            color: $textColor;
            opacity: 0.8;
        }
        
        table {
            border-collapse: collapse;
            width: 100%;
            margin: 16px 0;
        }
        
        table th,
        table td {
            padding: 8px 13px;
            border: 1px solid $borderColor;
        }
        
        table th {
            background-color: $codeColor;
            font-weight: 600;
        }
        
        table tr:nth-child(even) {
            background-color: $codeColor;
            opacity: 0.5;
        }
        
        img {
            max-width: 100%;
            height: auto;
        }
        
        hr {
            border: 0;
            border-top: 1px solid $borderColor;
            margin: 24px 0;
        }
        
        ul, ol {
            padding-left: 2em;
        }
        
        li {
            margin: 0.25em 0;
        }
        
        .toc {
            background-color: $codeColor;
            border: 1px solid $borderColor;
            border-radius: 6px;
            padding: 16px;
            margin: 20px 0;
        }
        
        .toc h2 {
            margin-top: 0;
            border-bottom: none;
        }
        
        @media print {
            body {
                max-width: 100%;
                padding: 20px;
            }
        }
    </style>
</head>
<body>
    <div id="content"></div>
    
    <script>
        // Configure marked options
        marked.setOptions({
            breaks: true,
            gfm: true,
            headerIds: true,
            mangle: false
        });
        
        // Markdown content
        const markdown = ``$mdContentEscaped``;
        
        // Convert and sanitize
        const rawHtml = marked.parse(markdown);
        const cleanHtml = DOMPurify.sanitize(rawHtml);
        
        // Insert into page
        document.getElementById('content').innerHTML = cleanHtml;
        
        // Add copy buttons to code blocks
        document.querySelectorAll('pre code').forEach((block) => {
            const button = document.createElement('button');
            button.innerText = 'Copy';
            button.style.cssText = 'position: absolute; top: 5px; right: 5px; padding: 4px 8px; font-size: 12px; cursor: pointer;';
            
            const pre = block.parentElement;
            pre.style.position = 'relative';
            
            button.addEventListener('click', () => {
                navigator.clipboard.writeText(block.textContent);
                button.innerText = 'Copied!';
                setTimeout(() => { button.innerText = 'Copy'; }, 2000);
            });
            
            pre.insertBefore(button, block);
        });
    </script>
</body>
</html>
"@
    
    # Write HTML file
    $htmlContent | Out-File -FilePath $HtmlFile -Encoding UTF8
    
    # Get file size
    $fileInfo = Get-Item $HtmlFile
    $sizeKB = [math]::Round($fileInfo.Length / 1KB, 2)
    
    Write-Host "  ✓ Created: $HtmlFile ($sizeKB KB)" -ForegroundColor Green
}

# Main execution
if ($InputFile -eq "*") {
    # Convert all .md files in current directory
    $mdFiles = Get-ChildItem -Filter "*.md" -File
    
    if ($mdFiles.Count -eq 0) {
        Write-Host "No .md files found in current directory." -ForegroundColor Yellow
        exit 1
    }
    
    Write-Host "Found $($mdFiles.Count) Markdown file(s)" -ForegroundColor Cyan
    Write-Host ""
    
    foreach ($mdFile in $mdFiles) {
        $htmlFile = [System.IO.Path]::ChangeExtension($mdFile.FullName, ".html")
        Convert-MarkdownFile -MdFile $mdFile.FullName -HtmlFile $htmlFile -Theme $Theme
    }
} else {
    # Convert single file
    if (-not (Test-Path $InputFile)) {
        Write-Host "Error: File not found: $InputFile" -ForegroundColor Red
        exit 1
    }
    
    $InputFile = Resolve-Path $InputFile
    
    if (-not $OutputFile) {
        $OutputFile = [System.IO.Path]::ChangeExtension($InputFile, ".html")
    }
    $OutputFile = [System.IO.Path]::GetFullPath($OutputFile)
    
    Convert-MarkdownFile -MdFile $InputFile -HtmlFile $OutputFile -Theme $Theme
}

Write-Host ""
Write-Host "Conversion complete!" -ForegroundColor Green
Write-Host "Open the HTML file(s) in your browser to view." -ForegroundColor Cyan
