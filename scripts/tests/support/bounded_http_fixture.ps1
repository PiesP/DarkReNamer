if (-not ('DarkReNamerBoundedHttpHandler' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

public sealed class DarkReNamerBoundedHttpHandler : HttpMessageHandler {
    public readonly Queue<HttpResponseMessage> Responses = new Queue<HttpResponseMessage>();
    public readonly List<string> Authorization = new List<string>();
    public readonly List<string> RequestUris = new List<string>();

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,
                                                             CancellationToken cancellationToken) {
        Authorization.Add(request.Headers.Authorization == null ? null :
                          request.Headers.Authorization.ToString());
        RequestUris.Add(request.RequestUri.ToString());
        return Task.FromResult(Responses.Dequeue());
    }
}
'@
}

function New-BoundedHttpFixture {
    $handler = [DarkReNamerBoundedHttpHandler]::new()
    [pscustomobject]@{
        Handler = $handler
        Client = [Net.Http.HttpClient]::new($handler, $false)
    }
}

function New-BoundedHttpResponse {
    param(
        [Parameter(Mandatory)][int] $Status,
        [byte[]] $Bytes = [byte[]]::new(0),
        [Nullable[long]] $ContentLength = $null,
        [string] $Location
    )
    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$Status)
    $response.Content = [Net.Http.ByteArrayContent]::new($Bytes)
    $response.Content.Headers.ContentLength = $ContentLength
    if ($Location) { $response.Headers.Location = [uri]$Location }
    $response
}
