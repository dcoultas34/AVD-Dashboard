# =============================================================================
# storage-api-helpers.ps1 - Azure Files data plane REST API helper functions
# Author  : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
# =============================================================================
#
# These functions use SharedKey authentication to call the Azure Files REST API
# directly, removing the dependency on the Az.Storage PowerShell module.
#
# Usage:
#   Designed to be loaded as a string and dot-sourced into background runspaces
#   via [scriptblock]::Create(). The calling script passes this file's content
#   as a parameter; the runspace dot-sources it at the start of execution.
#
# Requirements:
#   - Storage account name and key (obtained via ARM REST API listKeys).
#   - No PowerShell modules required (pure .NET / REST).
#
# Authentication:
#   All requests use the SharedKey authorisation scheme. The signing process
#   builds a canonical string-to-sign from the HTTP method, headers, and
#   resource path, then HMAC-SHA256 signs it with the storage account key.
#
# Logging:
#   When $LogFile is set (by the calling script), each REST call logs method,
#   URI, status code, and duration. Uses [IO.File]::AppendAllText for thread-safe
#   writes from background runspaces (same approach as the live dashboard's
#   compact Invoke-Arm helper).
#
# API version: 2024-11-04 (Azure Files REST API)
# =============================================================================

$StorageApiVersion = "2024-11-04"

# -----------------------------------------------------------------------------
# Invoke-StorageFileRest - low-level Azure Files REST call with SharedKey auth
# -----------------------------------------------------------------------------
# Returns the raw [Microsoft.PowerShell.Commands.WebResponseObject] so callers
# can inspect both .Content (body) and .Headers.
# -----------------------------------------------------------------------------

function Invoke-StorageFileRest {
    param(
        [string]$AccountName,
        [string]$AccountKey   = "",       # SharedKey auth (HMAC-SHA256) - provide this OR BearerToken
        [string]$BearerToken  = "",       # OAuth bearer token auth - provide this OR AccountKey
        [string]$Method,
        [string]$ShareName,
        [string]$Path,
        [hashtable]$QueryParams      = @{},
        [hashtable]$ExtraXmsHeaders  = @{},
        [string]$ContentType         = "",
        [byte[]]$BodyBytes           = $null
    )

    # -- Build URI and resource path -------------------------------------------
    $resourcePath = "/$ShareName"
    if ($Path) { $resourcePath += "/$Path" }

    $qsParts = @()
    foreach ($k in ($QueryParams.Keys | Sort-Object)) {
        $qsParts += "$k=$($QueryParams[$k])"
    }
    $queryString = if ($qsParts.Count -gt 0) { "?" + ($qsParts -join "&") } else { "" }
    $uri = "https://${AccountName}.file.core.windows.net${resourcePath}${queryString}"

    # -- x-ms-* headers (required for both auth methods) -----------------------
    $date = [DateTime]::UtcNow.ToString("R")
    $xmsHeaders = [ordered]@{}
    $xmsHeaders["x-ms-date"]    = $date
    $xmsHeaders["x-ms-version"] = $StorageApiVersion
    foreach ($k in ($ExtraXmsHeaders.Keys | Sort-Object)) {
        $xmsHeaders[$k.ToLower()] = $ExtraXmsHeaders[$k]
    }

    # -- Auth header -----------------------------------------------------------
    # Two auth methods are supported:
    #   1. Bearer token (OAuth) - uses Entra ID identity with RBAC role
    #      "Storage File Data Privileged Contributor" on the storage account.
    #      Simpler - no HMAC signing needed, just pass the token.
    #   2. SharedKey (HMAC-SHA256) - uses storage account primary key.
    #      Requires computing a signature over canonicalized headers/resource.
    if ($BearerToken) {
        # ── OAuth bearer token auth ──
        # No HMAC signing needed - just pass the token in the Authorization header.
        #
        # IMPORTANT: Azure Files REST API requires the "x-ms-file-request-intent"
        # header on EVERY data-plane call when authenticating with OAuth/Bearer tokens.
        # The only supported value is "backup". Without this header, the API returns:
        #   HTTP 400 - MissingRequiredHeader
        #   "An HTTP header that's mandatory for this request is not specified."
        #
        # This header is NOT required when using SharedKey (HMAC) authentication.
        # See: https://learn.microsoft.com/en-us/rest/api/storageservices/authorize-with-azure-active-directory
        $headers = @{
            "Authorization"             = "Bearer $BearerToken"
            "x-ms-file-request-intent"  = "backup"
        }
    } elseif ($AccountKey) {
        # SharedKey auth - compute HMAC-SHA256 signature
        $contentLength = ""
        if ($BodyBytes -and $BodyBytes.Length -gt 0) {
            $contentLength = $BodyBytes.Length.ToString()
        }

        $canonHeaders = ""
        foreach ($k in ($xmsHeaders.Keys | Sort-Object)) {
            $canonHeaders += "$($k):$($xmsHeaders[$k])`n"
        }

        $canonResource = "/$AccountName$resourcePath"
        foreach ($k in ($QueryParams.Keys | Sort-Object)) {
            $canonResource += "`n$($k.ToLower()):$($QueryParams[$k])"
        }

        $sts = @(
            $Method.ToUpper()   # VERB
            ""                  # Content-Encoding
            ""                  # Content-Language
            $contentLength      # Content-Length
            ""                  # Content-MD5
            $ContentType        # Content-Type
            ""                  # Date (empty - using x-ms-date)
            ""                  # If-Modified-Since
            ""                  # If-Match
            ""                  # If-None-Match
            ""                  # If-Unmodified-Since
            ""                  # Range
        ) -join "`n"
        $sts += "`n" + $canonHeaders + $canonResource

        $hmac = [System.Security.Cryptography.HMACSHA256]::new(
                    [Convert]::FromBase64String($AccountKey))
        $sig  = [Convert]::ToBase64String(
                    $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sts)))

        $headers = @{ "Authorization" = "SharedKey ${AccountName}:${sig}" }
    } else {
        throw "Invoke-StorageFileRest: Either -AccountKey or -BearerToken must be provided."
    }

    foreach ($k in $xmsHeaders.Keys) { $headers[$k] = $xmsHeaders[$k] }
    if ($ContentType) { $headers["Content-Type"] = $ContentType }

    # -- Make the request ------------------------------------------------------
    $splat = @{
        Uri             = $uri
        Method          = $Method
        Headers         = $headers
        UseBasicParsing = $true
        ErrorAction     = "Stop"
    }
    if ($BodyBytes -and $BodyBytes.Length -gt 0) {
        $splat["Body"] = $BodyBytes
    }
    # No Body for PUT without $BodyBytes - Azure Files accepts PUT with no body
    # for operations like forceclosehandles. Sending an empty byte array would
    # cause PS5.1 to add a default Content-Type header that breaks the signature.

    # Log the call if $LogFile is set (thread-safe via AppendAllText)
    $sw = $null
    if ($LogFile) { $sw = [System.Diagnostics.Stopwatch]::StartNew() }

    try {
        $resp = Invoke-WebRequest @splat
        if ($sw) {
            $sw.Stop()
            $logUri = "$($Method.ToUpper()) ${AccountName}.file${resourcePath}${queryString}"
            [IO.File]::AppendAllText($LogFile,
                "[$(Get-Date -Format 'HH:mm:ss')] $logUri -> $($resp.StatusCode) ($($sw.ElapsedMilliseconds)ms)`r`n")
        }
        return $resp
    } catch {
        if ($sw) {
            $sw.Stop()
            $logUri = "$($Method.ToUpper()) ${AccountName}.file${resourcePath}${queryString}"
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "ERR" }
            [IO.File]::AppendAllText($LogFile,
                "[$(Get-Date -Format 'HH:mm:ss')] $logUri -> $status FAILED ($($sw.ElapsedMilliseconds)ms): $($_.Exception.Message)`r`n")
        }
        throw
    }
}


# -----------------------------------------------------------------------------
# Get-StorageDirectoryFiles - list files in an Azure File Share directory
# -----------------------------------------------------------------------------
# Returns an array of XML elements, each with a .Name child.
# Returns @() if the directory does not exist (404).
# -----------------------------------------------------------------------------

function Get-StorageDirectoryFiles {
    param(
        [string]$AccountName,
        [string]$AccountKey  = "",
        [string]$BearerToken = "",
        [string]$ShareName,
        [string]$DirectoryPath
    )
    try {
        $resp = Invoke-StorageFileRest -AccountName $AccountName -AccountKey $AccountKey `
                    -BearerToken $BearerToken `
                    -Method "GET" -ShareName $ShareName -Path $DirectoryPath `
                    -QueryParams @{ restype = "directory"; comp = "list" }

        # Strip UTF-8 BOM that Invoke-WebRequest in PS5.1 may leave in the content
        # (appears as ï»¿ when the response encoding is misdetected as Windows-1252)
        $content = $resp.Content
        $xmlStart = $content.IndexOf('<')
        if ($xmlStart -gt 0) { $content = $content.Substring($xmlStart) }
        [xml]$xml = $content
        $files = @()
        if ($xml.EnumerationResults.Entries.File) {
            $files = @($xml.EnumerationResults.Entries.File)
        }
        return $files
    } catch {
        # 404 = directory does not exist in this storage account
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.Value__ -eq 404) {
            return @()
        }
        throw
    }
}


# -----------------------------------------------------------------------------
# Get-StorageFileHandles - list open SMB file handles on a directory/file
# -----------------------------------------------------------------------------
# Returns an array of handle XML elements with .HandleId, .Path, .ClientIp,
# .OpenTime properties. Returns @() if no handles are open.
# Supports -Recursive to include handles on nested files/directories.
# -----------------------------------------------------------------------------

function Get-StorageFileHandles {
    param(
        [string]$AccountName,
        [string]$AccountKey  = "",
        [string]$BearerToken = "",
        [string]$ShareName,
        [string]$Path,
        [switch]$Recursive
    )
    $extraHeaders = @{}
    if ($Recursive) { $extraHeaders["x-ms-recursive"] = "true" }

    try {
        $resp = Invoke-StorageFileRest -AccountName $AccountName -AccountKey $AccountKey `
                    -BearerToken $BearerToken `
                    -Method "GET" -ShareName $ShareName -Path $Path `
                    -QueryParams @{ comp = "listhandles" } `
                    -ExtraXmsHeaders $extraHeaders

        # Strip UTF-8 BOM (see Get-StorageDirectoryFiles for details)
        $content = $resp.Content
        $xmlStart = $content.IndexOf('<')
        if ($xmlStart -gt 0) { $content = $content.Substring($xmlStart) }
        [xml]$xml = $content
        $handles = @()
        if ($xml.EnumerationResults.Entries.Handle) {
            $handles = @($xml.EnumerationResults.Entries.Handle)
        }
        return $handles
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.Value__ -eq 404) {
            return @()
        }
        throw
    }
}


# -----------------------------------------------------------------------------
# Close-StorageFileHandles - force-close all open handles on a path
# -----------------------------------------------------------------------------
# Returns the number of handles closed (from the response header).
# Uses x-ms-handle-id: * to close ALL handles.
# -----------------------------------------------------------------------------

function Close-StorageFileHandles {
    param(
        [string]$AccountName,
        [string]$AccountKey  = "",
        [string]$BearerToken = "",
        [string]$ShareName,
        [string]$Path,
        [switch]$Recursive
    )
    $extraHeaders = @{ "x-ms-handle-id" = "*" }
    if ($Recursive) { $extraHeaders["x-ms-recursive"] = "true" }

    $resp = Invoke-StorageFileRest -AccountName $AccountName -AccountKey $AccountKey `
                -BearerToken $BearerToken `
                -Method "PUT" -ShareName $ShareName -Path $Path `
                -QueryParams @{ comp = "forceclosehandles" } `
                -ExtraXmsHeaders $extraHeaders

    $closed = 0
    if ($resp.Headers["x-ms-number-of-handles-closed"]) {
        $closed = [int]$resp.Headers["x-ms-number-of-handles-closed"]
    }
    return $closed
}


# -----------------------------------------------------------------------------
# Test-StorageFileExists - check whether a specific file exists in the share
# -----------------------------------------------------------------------------
# Returns $true if the file exists, $false otherwise.
# Uses HTTP HEAD to avoid downloading the file content.
# -----------------------------------------------------------------------------

function Test-StorageFileExists {
    param(
        [string]$AccountName,
        [string]$AccountKey  = "",
        [string]$BearerToken = "",
        [string]$ShareName,
        [string]$FilePath
    )
    try {
        Invoke-StorageFileRest -AccountName $AccountName -AccountKey $AccountKey `
            -BearerToken $BearerToken `
            -Method "HEAD" -ShareName $ShareName -Path $FilePath | Out-Null
        return $true
    } catch {
        return $false
    }
}


# -----------------------------------------------------------------------------
# Remove-StorageFileItem - delete a file from the Azure File Share
# -----------------------------------------------------------------------------

function Remove-StorageFileItem {
    param(
        [string]$AccountName,
        [string]$AccountKey  = "",
        [string]$BearerToken = "",
        [string]$ShareName,
        [string]$FilePath
    )
    Invoke-StorageFileRest -AccountName $AccountName -AccountKey $AccountKey `
        -BearerToken $BearerToken `
        -Method "DELETE" -ShareName $ShareName -Path $FilePath | Out-Null
}
