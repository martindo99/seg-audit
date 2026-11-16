param(
    [string]$Repository
)

$ErrorActionPreference = 'Stop'

$promptFile = Join-Path $PSScriptRoot 'prompt_seguridad.md'
$outDir = Join-Path $PSScriptRoot 'informes'

function Select-Option {
    param(
        [string]$Title,
        [string[]]$Options
    )

    Write-Host ""
    Write-Host $Title
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ("  {0}) {1}" -f ($i + 1), $Options[$i])
    }

    while ($true) {
        $selection = Read-Host "Elegi una opcion [1-$($Options.Count)]"
        $number = 0
        if ([int]::TryParse($selection, [ref]$number) -and
            $number -ge 1 -and $number -le $Options.Count) {
            return $Options[$number - 1]
        }
        Write-Host 'Opcion invalida.'
    }
}

if (-not $Repository) {
    $currentDirectory = (Get-Location).Path
    $Repository = Read-Host "Ruta del repo a auditar [$currentDirectory]"
    if (-not $Repository) {
        $Repository = $currentDirectory
    }
}
if (-not (Test-Path -LiteralPath $Repository -PathType Container)) {
    throw "No existe el directorio: $Repository"
}
$repo = (Resolve-Path -LiteralPath $Repository).ProviderPath
$repoName = Split-Path -Path $repo -Leaf
$repoBranch = ''
$repoCommit = ''
$repoDirty = 'no'

if (Get-Command git -ErrorAction SilentlyContinue) {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $repoBranch = (& git -C $repo branch --show-current 2>$null | Out-String).Trim()
        $repoCommit = (& git -C $repo rev-parse --short HEAD 2>$null | Out-String).Trim()
        $status = (& git -C $repo status --porcelain 2>$null | Out-String).Trim()
        if ($status) {
            $repoDirty = 'si'
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}
if (-not $repoBranch) { $repoBranch = 'HEAD separado o no es un repo Git' }
if (-not $repoCommit) { $repoCommit = 'desconocido' }

$choice = Select-Option 'Que CLI queres usar?' @('Claude Code', 'GitHub Copilot CLI')
$engine = if ($choice -eq 'Claude Code') { 'claude' } else { 'copilot' }
if (-not (Get-Command $engine -ErrorAction SilentlyContinue)) {
    throw "No encuentro '$engine' en el PATH."
}

Write-Host ''
Write-Host 'Modelo: escribi el nombre y presiona Enter.'
if ($engine -eq 'claude') {
    Write-Host '  Claude Code acepta alias (sonnet, opus, haiku, fable, best) o un nombre completo.'
}
else {
    Write-Host '  Copilot CLI: usa el nombre exacto que muestra /model dentro de una sesion.'
}
Write-Host '  Dejalo vacio para usar el modelo predeterminado de la CLI.'
$model = Read-Host 'Modelo'
$modelArgs = @()
$modelLabel = 'predeterminado'
if ($model) {
    $modelArgs = @('--model', $model)
    $modelLabel = $model
}

New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$runDir = Join-Path $outDir "${repoName}_$stamp"
$report = Join-Path $runDir 'informe.md'
$osvJson = Join-Path $runDir 'osv.json'
$semgrepJson = Join-Path $runDir 'semgrep.json'
$gitleaksJson = Join-Path $runDir 'gitleaks.json'

Write-Host ''
Write-Host 'Resumen:'
Write-Host "  Repositorio : $repo"
Write-Host "  Branch      : $repoBranch"
Write-Host "  Commit      : $repoCommit"
Write-Host "  Cambios     : $repoDirty"
Write-Host "  CLI         : $engine"
Write-Host "  Modelo      : $modelLabel"
Write-Host "  Carpeta     : $runDir"
Write-Host "  Informe     : $report"
Write-Host "  JSON Gitleaks: $gitleaksJson"
$confirmation = Read-Host 'Ejecutar la auditoria? [s/N]'
if ($confirmation -notmatch '^[sSyY]$') {
    Write-Host 'Cancelado.'
    exit 0
}

New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$prompt = (Get-Content -LiteralPath $promptFile -Raw -Encoding UTF8) + @"

Rutas de salida:
- Informe: $report
- JSON de OSV: $osvJson
- JSON de Semgrep: $semgrepJson
- JSON de Gitleaks: $gitleaksJson

Contexto del checkout auditado:
- Branch: $repoBranch
- Commit: $repoCommit
- Cambios locales sin commit: $repoDirty
"@

Push-Location -LiteralPath $repo
try {
    if ($engine -eq 'claude') {
        & claude -p $prompt @modelArgs --add-dir $runDir `
            --allowedTools 'Bash(osv-scanner:*) Bash(semgrep:*) Bash(gitleaks:*) Bash(npm:*) Bash(pip-audit:*) Bash(grep:*) Bash(curl:*) Read Grep Glob Write'
    }
    else {
        & copilot -p $prompt @modelArgs -s --no-ask-user --add-dir $runDir `
            '--allow-tool=read' `
            '--allow-tool=write' `
            '--allow-tool=shell(osv-scanner)' `
            '--allow-tool=shell(semgrep)' `
            '--allow-tool=shell(gitleaks)' `
            '--allow-tool=shell(npm)' `
            '--allow-tool=shell(pip-audit)' `
            '--allow-tool=shell(grep)' `
            '--allow-tool=shell(curl)'
    }
    $exitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}
if ($exitCode -ne 0) {
    throw "La CLI '$engine' termino con codigo de salida $exitCode."
}

Write-Host ''
Write-Host "Resultados generados en: $runDir"
