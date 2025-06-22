# Get all relevant code and markdown files recursively
$files = Get-ChildItem -Path .\ -Recurse -Include *.js, *.jsx, *.go, *.cs, *.md

# Define the output file
$outputFile = "code.md"

# Create or overwrite the output file
New-Item -Path $outputFile -ItemType File -Force | Out-Null

# Define a mapping from file extensions to language identifiers
$languageMap = @{
    ".js"   = "javascript"
    ".jsx"  = "javascript"
    ".go"   = "go"
    ".cs"   = "csharp"
    ".md"   = "markdown"
}

# Loop through each file and process
foreach ($file in $files) {
    try {
        # Add the file name as an H1 header
        Add-Content -Path $outputFile -Value "# $($file.Name)"
        
        # Read the file's contents
        $code = Get-Content -Path $file.FullName -Raw
        
        # Determine the language from the file extension
        $extension = $file.Extension.ToLower()
        $language = if ($languageMap.ContainsKey($extension)) { $languageMap[$extension] } else { "text" }

        # Write the code block with the appropriate language
        Add-Content -Path $outputFile -Value "+++$language"
        Add-Content -Path $outputFile -Value $code
        Add-Content -Path $outputFile -Value "+++"

        # Add a blank line to separate files
        Add-Content -Path $outputFile -Value ""
    } catch {
        Write-Host "Error processing file $($file.FullName): $($_.Exception.Message)" -ForegroundColor Red
    }
}
