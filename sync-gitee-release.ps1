param([switch]$PruneGitHub, [switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$githubRepo = 'BigWai1312/tiktok-uploader-releases'
$giteeRepo = 'leecode312/tiktok-uploader-releases'
$giteeApi = "https://gitee.com/api/v5/repos/$giteeRepo"

function Get-InstallerName($release) {
  if ($release.draft -or $release.prerelease -or $release.tag_name -cnotmatch '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
    throw 'Expected a stable canonical GitHub release'
  }
  $name = "TikTokUploader-$($release.tag_name.Substring(1))-Setup.exe"
  foreach ($filename in @($name, "$name.sha256")) {
    $asset = @($release.assets | Where-Object { $_.name -ceq $filename })
    if ($asset.Count -ne 1 -or $asset[0].browser_download_url -cne "https://github.com/$githubRepo/releases/download/$($release.tag_name)/$filename") {
      throw "Missing official GitHub asset: $filename"
    }
  }
  return $name
}

function Get-GiteeJson([string]$Url) {
  for ($attempt = 0; ; $attempt++) {
    try { return Invoke-RestMethod $Url -Headers $headers -TimeoutSec 60 }
    catch {
      $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
      if ($attempt -ge 1 -or ($status -ge 400 -and $status -lt 500 -and $status -notin @(408, 429))) { throw }
      Start-Sleep -Seconds 3
    }
  }
}

if ($SelfTest) {
  $fixture = @{ tag_name='v1.2.3'; draft=$false; prerelease=$false; assets=@() }
  foreach ($name in @('TikTokUploader-1.2.3-Setup.exe', 'TikTokUploader-1.2.3-Setup.exe.sha256')) {
    $fixture.assets += @{name=$name;browser_download_url="https://github.com/$githubRepo/releases/download/v1.2.3/$name"}
  }
  if ((Get-InstallerName $fixture) -cne 'TikTokUploader-1.2.3-Setup.exe') { throw 'Installer parsing failed' }
  foreach ($tag in @('v01.2.3', 'v1.2', 'v1.2.3-beta', '../v1.2.3')) {
    $fixture.tag_name=$tag
    $rejected=$false
    try { Get-InstallerName $fixture | Out-Null } catch { $rejected=$true }
    if (-not $rejected) { throw "Unsafe tag accepted: $tag" }
  }
  $fixture.tag_name='v1.2.3'
  $fixture.assets[0].browser_download_url='https://example.invalid/installer.exe'
  $rejected=$false
  try { Get-InstallerName $fixture | Out-Null } catch { $rejected=$true }
  if (-not $rejected) { throw 'Unofficial installer accepted' }
  Write-Output 'PASS: stable version, required asset pair, canonical names and official URLs.'
  return
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) "tiktok-release-sync-$([Guid]::NewGuid().ToString('N'))"
$headers = @{}
$secure = $null
try {
  $token = $env:GITEE_TOKEN
  if (-not $token) {
    $secretPath = Join-Path (Split-Path -Parent $PSScriptRoot) '.secrets\gitee-token.dpapi'
    if (-not $IsWindows -or -not (Test-Path -LiteralPath $secretPath)) { throw 'Set GITEE_TOKEN or provision the local Windows DPAPI credential' }
    $secure = ConvertTo-SecureString ([IO.File]::ReadAllText($secretPath))
    $token = ([PSCredential]::new('gitee', $secure)).GetNetworkCredential().Password
  }
  $headers.Authorization = "Bearer $($token.Trim())"
  $token = $null
  $source = Invoke-RestMethod "https://api.github.com/repos/$githubRepo/releases/latest" -Headers @{'User-Agent'='TikTokUploader-release-sync'} -TimeoutSec 30
  $installer = Get-InstallerName $source
  New-Item -ItemType Directory -Path $temporary | Out-Null
  foreach ($name in @($installer, "$installer.sha256")) {
    Invoke-WebRequest "https://github.com/$githubRepo/releases/download/$($source.tag_name)/$name" -OutFile (Join-Path $temporary $name) -TimeoutSec 300
  }
  $hash = (Get-FileHash -LiteralPath (Join-Path $temporary $installer) -Algorithm SHA256).Hash
  $checksum = [IO.File]::ReadAllText((Join-Path $temporary "$installer.sha256")).Trim()
  if ($checksum -cnotmatch "^([A-Fa-f0-9]{64})  $([regex]::Escape($installer))$" -or $Matches[1] -ine $hash) { throw 'GitHub installer checksum mismatch' }
  $digest = ($source.assets | Where-Object name -CEQ $installer).digest
  if ($digest -and $digest -ine "sha256:$hash") { throw 'GitHub asset digest mismatch' }
  $releases = Get-GiteeJson "$giteeApi/releases?per_page=100"
  $release = $releases | Where-Object tag_name -CEQ $source.tag_name | Select-Object -First 1
  $body = @{ tag_name=$source.tag_name; name=$source.name; body=$source.body; target_commitish='main'; prerelease=$true }
  if (-not $release) {
    $release = Invoke-RestMethod "$giteeApi/releases" -Method Post -Headers $headers -ContentType 'application/json' -Body ($body | ConvertTo-Json) -TimeoutSec 30
  }
  $attachments = Get-GiteeJson "$giteeApi/releases/$($release.id)/attach_files?per_page=100"
  foreach ($name in @($installer, "$installer.sha256")) {
    $file = Get-Item -LiteralPath (Join-Path $temporary $name)
    $attachment = $attachments | Where-Object name -CEQ $name | Select-Object -First 1
    if (-not $attachment) {
      $curl = if ($IsWindows) { 'curl.exe' } else { 'curl' }
      for ($attempt = 0; $attempt -lt 2; $attempt++) {
        Write-Output "Uploading $name (attempt $($attempt + 1))"
        # Headers go through stdin so the token is absent from process arguments.
        $uploaded = "Authorization: $($headers.Authorization)" | & $curl --silent --show-error --fail --http1.1 `
          --connect-timeout 30 --max-time 300 --header '@-' --header 'Expect:' --form "file=@$($file.FullName)" "$giteeApi/releases/$($release.id)/attach_files"
        if ($LASTEXITCODE -eq 0) { $attachment = ($uploaded -join "`n") | ConvertFrom-Json; break }
        Start-Sleep -Seconds 2
        $saved = Get-GiteeJson "$giteeApi/releases/$($release.id)/attach_files?per_page=100"
        $attachment = $saved | Where-Object name -CEQ $name | Select-Object -First 1
        if ($attachment) { break }
      }
      if (-not $attachment) { throw "Gitee upload failed: $name; previous releases were preserved" }
    }
    $url = "https://gitee.com/$giteeRepo/releases/download/$($source.tag_name)/$name"
    if ($attachment.browser_download_url -cne $url) { throw 'Unexpected Gitee attachment URL' }
    $downloaded = Join-Path $temporary "verified-$name"
    # No authorization: installers must also be downloadable by ordinary users.
    Invoke-WebRequest $url -OutFile $downloaded -TimeoutSec 300
    if ((Get-FileHash -LiteralPath $downloaded -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) {
      throw "Gitee download checksum mismatch: $name; existing assets were preserved"
    }
  }
  $body.prerelease = $false
  Invoke-RestMethod "$giteeApi/releases/$($release.id)" -Method Patch -Headers $headers -ContentType 'application/json' -Body ($body | ConvertTo-Json) -TimeoutSec 30 | Out-Null
  foreach ($old in $releases | Where-Object { $_.id -ne $release.id -and $_.tag_name -match '^v\d+\.\d+\.\d+$' }) {
    Invoke-RestMethod "$giteeApi/releases/$($old.id)" -Method Delete -Headers $headers -TimeoutSec 30 | Out-Null
  }
  if ($PruneGitHub) {
    $oldReleases = gh release list --repo $githubRepo --limit 100 --json tagName | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Cannot list old GitHub releases' }
    foreach ($old in $oldReleases | Where-Object { $_.tagName -cne $source.tag_name -and $_.tagName -match '^v\d+\.\d+\.\d+$' }) {
      gh release delete $old.tagName --repo $githubRepo --yes --cleanup-tag
      if ($LASTEXITCODE -ne 0) { throw 'Cannot remove an old public installer release' }
    }
  }
  Write-Output "mirror=https://gitee.com/$giteeRepo/releases/tag/$($source.tag_name)"
  Write-Output "sha256=$hash"
} finally {
  $headers.Clear()
  if ($secure) { $secure.Dispose() }
  $resolved = [IO.Path]::GetFullPath($temporary)
  if ([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') -or
      [IO.Path]::GetFileName($resolved) -notmatch '^tiktok-release-sync-[a-f0-9]{32}$') { throw 'Invalid cleanup path' }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
