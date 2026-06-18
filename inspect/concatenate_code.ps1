# ------------------------------------------------------------
# OUTPUT FILE (WITH TIMESTAMP)
# ------------------------------------------------------------

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$outputFile = "code-$timestamp.md"

# ------------------------------------------------------------
# LANGUAGE MAP
# ------------------------------------------------------------

$languageMap = @{
    ".js"   = "javascript"
    ".jsx"  = "javascript"
    ".go"   = "go"
    ".cs"   = "csharp"
    ".md"   = "markdown"
    ".py"   = "python"
    ".ps1"  = "powershell"
    ".psd1" = "powershell"
    ".psm1" = "powershell"
    ".json" = "json"
    ".yaml" = "yaml"
    ".yml"  = "yaml"
}

# ------------------------------------------------------------
# FILE COLLECTION
# ------------------------------------------------------------

$files = Get-ChildItem -Path . -Recurse -File -Include `
    *.js, *.jsx, *.go, *.cs, *.md, *.py, `
    *.ps1, *.psd1, *.psm1, `
    *.json, *.yaml, *.yml, *.pt |
    Where-Object {
        $_.FullName -notmatch '\\.git\\' -and
        $_.FullName -notmatch 'node_modules'
    } |
    Sort-Object FullName

# ------------------------------------------------------------
# WRITE OUTPUT
# ------------------------------------------------------------

$writer = [System.IO.StreamWriter]::new($outputFile, $false)

try {
    foreach ($file in $files) {

        $relPath = Resolve-Path -Relative $file.FullName
        $writer.WriteLine("# " + $relPath)
        $writer.WriteLine("")

        $ext = $file.Extension.ToLower()

        if ($ext -eq ".pt") {
            $writer.WriteLine("*Binary PyTorch artifact. Content omitted.*")
            $writer.WriteLine("")
            continue
        }

        if ($languageMap.ContainsKey($ext)) {
            $language = $languageMap[$ext]
        } else {
            $language = "text"
        }

        $writer.WriteLine("```" + $language)

        try {
            $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
            $writer.WriteLine($content)
        } catch {
            $writer.WriteLine("[Error reading file]")
        }

        $writer.WriteLine("```")
        $writer.WriteLine("")
    }
}
finally {
    $writer.Close()
}

Write-Host ("Generated: " + $outputFile) -ForegroundColor Green