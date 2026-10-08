[CmdletBinding()]
param([switch] $LibraryOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-BoundedDownloadSize {
    param(
        [Parameter(Mandatory)][object] $Size,
        [Parameter(Mandatory)][long] $Maximum,
        [Parameter(Mandatory)][string] $Label
    )
    if ($Size -isnot [long] -or $Size -le 0 -or $Size -gt $Maximum) {
        throw "$Label must be a positive JSON integer no larger than $Maximum bytes."
    }
}

function Copy-BoundedDownloadStream {
    param(
        [Parameter(Mandatory)][IO.Stream] $Stream,
        [Parameter(Mandatory)][string] $OutputPath,
        [Parameter(Mandatory)][long] $ExpectedSize,
        [Parameter(Mandatory)][long] $MaximumBytes,
        [Threading.CancellationToken] $CancellationToken = [Threading.CancellationToken]::None
    )
    if ($ExpectedSize -le 0 -or $ExpectedSize -gt $MaximumBytes) {
        throw 'Download size is outside its bounded allocation policy.'
    }
    # CreateNew preserves an earlier failed receipt. A new partial file is kept
    # if the response body later exceeds its advertised size or the request fails.
    $output = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $buffer = [byte[]]::new(65536)
        $written = [long]0
        while ($true) {
            $CancellationToken.ThrowIfCancellationRequested()
            $remaining = $ExpectedSize - $written
            $readLength = [int][Math]::Min($buffer.Length, $remaining + 1)
            $count = $Stream.ReadAsync($buffer, 0, $readLength, $CancellationToken).GetAwaiter().GetResult()
            if ($count -eq 0) { break }
            if ($written + $count -gt $ExpectedSize -or $written + $count -gt $MaximumBytes) {
                throw 'Downloaded body exceeds the approved or configured byte limit.'
            }
            $output.Write($buffer, 0, $count)
            $written += $count
        }
        if ($written -ne $ExpectedSize) {
            throw "Downloaded body size differs from authenticated metadata: $written versus $ExpectedSize."
        }
        $output.Flush($true)
    }
    finally {
        $output.Dispose()
    }
}

function Save-BoundedGitHubData {
    param(
        [Parameter(Mandatory)][uri] $ApiUri,
        [Parameter(Mandatory)][string] $OutputPath,
        [Parameter(Mandatory)][long] $ExpectedSize,
        [Parameter(Mandatory)][long] $MaximumBytes,
        [Parameter(Mandatory)][string] $Token,
        [ValidateSet('application/vnd.github+json', 'application/octet-stream')]
        [string] $Accept = 'application/octet-stream',
        [ValidateRange(1, 600)][int] $TimeoutSeconds = 300,
        [Net.Http.HttpClient] $Client
    )
    if ($ApiUri.Scheme -cne 'https' -or $ApiUri.Host -cne 'api.github.com' -or
        $ApiUri.Port -ne 443 -or
        -not [string]::IsNullOrEmpty($ApiUri.UserInfo) -or
        -not [string]::IsNullOrEmpty($ApiUri.Query) -or
        -not [string]::IsNullOrEmpty($ApiUri.Fragment) -or
        $ApiUri.AbsolutePath -cnotmatch '^/repos/[^/]+/[^/]+/(?:actions/artifacts/[1-9][0-9]*/zip|releases/assets/[1-9][0-9]*)$') {
        throw 'Download origin must be an exact GitHub artifact or release asset API endpoint.'
    }
    if ([string]::IsNullOrWhiteSpace($Token) -or $ExpectedSize -le 0 -or
        $ExpectedSize -gt $MaximumBytes -or $MaximumBytes -le 0) {
        throw 'Bounded GitHub download inputs are invalid.'
    }
    if (Test-Path -LiteralPath $OutputPath) {
        throw 'Bounded download output already exists.'
    }
    $ownClient = $null -eq $Client
    if ($ownClient) {
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $handler.UseCookies = $false
        $handler.AutomaticDecompression = [Net.DecompressionMethods]::None
        $Client = [Net.Http.HttpClient]::new($handler, $true)
        $Client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    }
    $deadline = [Threading.CancellationTokenSource]::new()
    $deadline.CancelAfter([TimeSpan]::FromSeconds($TimeoutSeconds))
    $current = $ApiUri
    try {
        for ($redirects = 0; $redirects -le 5; $redirects++) {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $current)
            $response = $null
            try {
                $request.Headers.UserAgent.ParseAdd('DarkReNamer-release-data/1.0')
                if ($redirects -eq 0) {
                    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
                    $request.Headers.Accept.ParseAdd($Accept)
                    [void]$request.Headers.TryAddWithoutValidation('X-GitHub-Api-Version', '2022-11-28')
                }
                $response = $Client.SendAsync($request,
                    [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
                    $deadline.Token).GetAwaiter().GetResult()
                $status = [int]$response.StatusCode
                if ($status -in @(301, 302, 303, 307, 308)) {
                    if ($redirects -eq 5 -or $null -eq $response.Headers.Location) {
                        throw 'GitHub download exceeded its redirect limit or omitted Location.'
                    }
                    $next = [uri]::new($current, $response.Headers.Location)
                    if ($next.Scheme -cne 'https' -or
                        -not [string]::IsNullOrEmpty($next.UserInfo)) {
                        throw 'GitHub download redirected to an unsupported URL.'
                    }
                    $current = $next
                    continue
                }
                if ($status -ne 200) {
                    throw "GitHub data download failed with HTTP $status; check asset availability and token access."
                }
                $length = $response.Content.Headers.ContentLength
                if ($null -ne $length -and $length -ne $ExpectedSize) {
                    throw 'GitHub download Content-Length differs from authenticated metadata.'
                }
                $body = $response.Content.ReadAsStreamAsync($deadline.Token).GetAwaiter().GetResult()
                try {
                    Copy-BoundedDownloadStream -Stream $body -OutputPath $OutputPath `
                        -ExpectedSize $ExpectedSize -MaximumBytes $MaximumBytes `
                        -CancellationToken $deadline.Token
                }
                finally {
                    $body.Dispose()
                }
                return
            }
            finally {
                if ($null -ne $response) { $response.Dispose() }
                $request.Dispose()
            }
        }
    }
    finally {
        $deadline.Dispose()
        if ($ownClient) { $Client.Dispose() }
    }
}
