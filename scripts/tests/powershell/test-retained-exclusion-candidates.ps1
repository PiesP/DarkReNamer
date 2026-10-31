[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Retained exclusion candidate runtime fixture requires Windows.' }

# This is a disposable TxF observation, not an exclusion or disposition implementation.
# In particular, CreateFileTransactedW below uses a fixture pathname; production
# owned-root traversal opens each component relative to held handles instead.
$source = Join-Path $PSScriptRoot '../../modules/powershell/controller-owned-root-guard.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Production guard source did not parse.' }
$definitions = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
    $node.StringConstantType -eq [Management.Automation.Language.StringConstantType]::SingleQuotedHereString -and
    $node.Value.Contains('public sealed class DarkReNamerVmOwnedRootGuard')
}, $true))
if ($definitions.Count -ne 1) { throw 'Expected exactly one source-bound production guard.' }
Add-Type -TypeDefinition $definitions[0].Value

Add-Type @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class DrTxCandidateNative {
    public const uint READ_DATA = 0x00000001, WRITE_DATA = 0x00000002;
    public const uint SHARE_READ = 1, SHARE_ALL = 7, OPEN_EXISTING = 3, CREATE_NEW = 1;
    public const uint FILE_ATTRIBUTE_NORMAL = 0x80, BACKUP_SEMANTICS = 0x02000000;
    public sealed class OpenResult {
        public SafeFileHandle Handle;
        public int Error;
        public bool Accepted { get { return Handle != null && !Handle.IsInvalid; } }
    }
    [DllImport("KtmW32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateTransaction(IntPtr attributes, IntPtr uow,
        uint options, uint isolationLevel, uint isolationFlags, uint timeout, string description);
    [DllImport("KtmW32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool RollbackTransaction(SafeFileHandle transaction);
    [DllImport("kernel32.dll", EntryPoint="CreateFileTransactedW", CharSet=CharSet.Unicode,
        ExactSpelling=true, SetLastError=true)]
    static extern SafeFileHandle CreateFileTransactedW(string path, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr templateFile,
        SafeFileHandle transaction, IntPtr miniVersion, IntPtr extended);
    [DllImport("kernel32.dll", EntryPoint="CreateFileW", CharSet=CharSet.Unicode,
        ExactSpelling=true, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr templateFile);
    [DllImport("kernel32.dll", EntryPoint="MoveFileExW", CharSet=CharSet.Unicode,
        ExactSpelling=true, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool MoveFileExW(string oldPath, string newPath, uint flags);
    public static OpenResult Begin() {
        SafeFileHandle h = CreateTransaction(IntPtr.Zero, IntPtr.Zero, 0, 0, 0, 0, null);
        int error = Marshal.GetLastWin32Error();
        return new OpenResult { Handle=h, Error=h.IsInvalid ? error : 0 };
    }
    public static OpenResult TxRead(string path, SafeFileHandle transaction) {
        SafeFileHandle h = CreateFileTransactedW(path, READ_DATA, SHARE_ALL,
            IntPtr.Zero, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero,
            transaction, IntPtr.Zero, IntPtr.Zero);
        int error = Marshal.GetLastWin32Error();
        return new OpenResult { Handle=h, Error=h.IsInvalid ? error : 0 };
    }
    public static OpenResult TxDirectoryRead(string path, SafeFileHandle transaction) {
        SafeFileHandle h = CreateFileTransactedW(path, READ_DATA, SHARE_ALL,
            IntPtr.Zero, OPEN_EXISTING, BACKUP_SEMANTICS, IntPtr.Zero,
            transaction, IntPtr.Zero, IntPtr.Zero);
        int error = Marshal.GetLastWin32Error();
        return new OpenResult { Handle=h, Error=h.IsInvalid ? error : 0 };
    }
    public static OpenResult Writer(string path, uint creation) {
        SafeFileHandle h = CreateFileW(path, WRITE_DATA, SHARE_ALL, IntPtr.Zero,
            creation, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        int error = Marshal.GetLastWin32Error();
        return new OpenResult { Handle=h, Error=h.IsInvalid ? error : 0 };
    }
    public static int Write(SafeFileHandle handle, byte value) {
        try {
            using (FileStream stream = new FileStream(handle, FileAccess.Write, 1, false)) {
                stream.WriteByte(value);
                stream.Flush(true);
            }
            return 0;
        } catch (IOException error) { return Marshal.GetHRForException(error); }
          catch (UnauthorizedAccessException error) { return Marshal.GetHRForException(error); }
    }
    public static int Rename(string source, string destination) {
        if (MoveFileExW(source, destination, 0)) return 0;
        return Marshal.GetLastWin32Error();
    }
    public static int Replace(string source, string destination) {
        if (MoveFileExW(source, destination, 1)) return 0;
        return Marshal.GetLastWin32Error();
    }
    public static int Rollback(SafeFileHandle transaction) {
        if (RollbackTransaction(transaction)) return 0;
        return Marshal.GetLastWin32Error();
    }
}
'@

function Write-Observation([string] $Case, [hashtable] $Fields) {
    $record = [ordered]@{ schema = 'darkrenamer-gate1-txf-candidate-v1'; case = $Case }
    foreach ($key in $Fields.Keys) { $record[$key] = $Fields[$key] }
    Write-Output ('DR_GATE1_CANDIDATE ' + ($record | ConvertTo-Json -Compress -Depth 5))
}

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-FileBytes([string] $Path, [byte[]] $Bytes) {
    try { $actual = [IO.File]::ReadAllBytes($Path) }
    catch {
        Write-Observation 'unexpected-fixture-poststate' @{ exists=$false; expected_bytes=$Bytes.Length }
        throw
    }
    $expectedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
    $actualHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($actual))
    if ($actual.Length -ne $Bytes.Length -or $actualHash -cne $expectedHash) {
        Write-Observation 'unexpected-fixture-poststate' @{
            exists=$true; expected_bytes=$Bytes.Length; actual_bytes=$actual.Length
            expected_sha256=$expectedHash.ToLowerInvariant()
            actual_sha256=$actualHash.ToLowerInvariant()
        }
        throw 'Owned fixture content differs from the independent expected bytes.'
    }
}

function New-Fixture([string] $Label) {
    $path = Join-Path $base ('DarkReNamerTests-' + [guid]::NewGuid().ToString('N'))
    Assert-True (-not [IO.Directory]::Exists($path)) 'Fresh fixture already exists.'
    [IO.Directory]::CreateDirectory($path) | Out-Null
    $script:fixtures.Add([pscustomobject]@{ label=$Label; path=$path; base_id=$null; root_id=$null })
    return $script:fixtures[$script:fixtures.Count - 1]
}

function New-Guard($Fixture) {
    $guard = [DarkReNamerVmOwnedRootGuard]::new($Fixture.path, $true)
    if ($null -eq $Fixture.root_id) {
        $Fixture.base_id = $guard.BaseId
        $Fixture.root_id = $guard.RootId
    }
    $guard.Assert($Fixture.base_id, $Fixture.root_id)
    return $guard
}

function Assert-Index($Guard, [int] $Expected) {
    $Guard.Assert($Guard.BaseId, $Guard.RootId)
    $rows = @($Guard.ContentIndex())
    Assert-True ($rows.Count -eq $Expected) 'Production content index missed a fixture entry.'
    return ,$rows
}

function Close-Transaction($Read, $Transaction, $DirectoryRead = $null) {
    if ($null -ne $Read -and $null -ne $Read.Handle) { $Read.Handle.Dispose() }
    if ($null -ne $DirectoryRead -and $null -ne $DirectoryRead.Handle) { $DirectoryRead.Handle.Dispose() }
    if ($null -ne $Transaction -and $null -ne $Transaction.Handle) {
        try {
            if ($Transaction.Accepted) {
                $errorCode = [DrTxCandidateNative]::Rollback($Transaction.Handle)
                Write-Observation 'rollback' @{ accepted=($errorCode -eq 0); native_error=$errorCode; read_handle_closed_first=$true }
                Assert-True ($errorCode -eq 0) "Fixture transaction rollback failed: $errorCode"
            }
        } finally { $Transaction.Handle.Dispose() }
    }
}

$base = Join-Path $env:ProgramData 'DarkReNamerVmRuns'
if (-not [IO.Directory]::Exists($base)) { [IO.Directory]::CreateDirectory($base) | Out-Null }
$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($base))
if ($drive.DriveFormat -cne 'NTFS') {
    Write-Observation 'capability' @{ available=$false; volume_format=$drive.DriveFormat; gate='BLOCKED'; target_collection=0; disposition=0; product=0 }
}
Assert-True ($drive.DriveFormat -ceq 'NTFS') 'TxF fixture requires an NTFS ProgramData volume; Gate 1 is inconclusive.'
$fixtures = [Collections.Generic.List[object]]::new()
$expected = [Collections.Generic.List[object]]::new()
$guard = $null
$tx = $null
$read = $null
$directoryRead = $null
$heldChild = $null
$writer = $null
$complete = $false
$limits = [Collections.Generic.List[string]]::new()
$flags = [Reflection.BindingFlags]'NonPublic,Instance,Static'
$openRelative = [DarkReNamerVmOwnedRootGuard].GetMethod('OpenRelative', $flags)
try {
    # A successful quiescent acquisition is required. Unsupported TxF is an
    # inconclusive failing observation, never a passing skip.
    $fixture = New-Fixture 'held-child-streams'
    $file = Join-Path $fixture.path 'content.txt'
    $original = [byte[]](66, 65, 83, 69)
    [IO.File]::WriteAllBytes($file, $original)
    $expected.Add([pscustomobject]@{path=$file; bytes=$original})
    $guard = New-Guard $fixture
    $null = Assert-Index $guard 1
    $tx = [DrTxCandidateNative]::Begin()
    Write-Observation 'create-transaction' @{ accepted=$tx.Accepted; native_error=$tx.Error; options='0'; isolation='0'; timeout='0' }
    Assert-True $tx.Accepted "CreateTransaction unavailable: $($tx.Error); Gate 1 inconclusive."
    $read = [DrTxCandidateNative]::TxRead($file, $tx.Handle)
    Write-Observation 'quiescent-transacted-read' @{ accepted=$read.Accepted; native_error=$read.Error; access='FILE_READ_DATA(0x1)'; share='READ|WRITE|DELETE(0x7)'; disposition='OPEN_EXISTING'; flags='FILE_ATTRIBUTE_NORMAL(0x80)' }
    Assert-True $read.Accepted "Quiescent CreateFileTransactedW failed: $($read.Error); Gate 1 inconclusive."
    $chain = [DarkReNamerVmOwnedRootGuard].GetField('chain', $flags).GetValue($guard)
    $heldChild = $openRelative.Invoke($null, @($chain[$chain.Count - 1], 'content.txt', $true))
    $ads = $file + ':while-held'
    $writer = [DrTxCandidateNative]::Writer($ads, [DrTxCandidateNative]::CREATE_NEW)
    $adsOpen = $writer.Accepted
    $adsWrite = $null
    if ($adsOpen) { $adsWrite = [DrTxCandidateNative]::Write($writer.Handle, 65) }
    Write-Observation 'new-ads-while-held' @{ open_accepted=$adsOpen; open_win32_error=$writer.Error; write_accepted=($adsWrite -eq 0); write_hresult=$adsWrite; access='FILE_WRITE_DATA(0x2)'; share='READ|WRITE|DELETE(0x7)'; disposition='CREATE_NEW'; guard_child='READ_ATTRIBUTES|LIST_DIRECTORY|READ_CONTROL|DELETE|SYNCHRONIZE;SHARE_READ' }
    if ($adsOpen) { $limits.Add('named-stream-created') }
    $writer.Handle.Dispose(); $writer = $null
    $writer = [DrTxCandidateNative]::Writer($file, [DrTxCandidateNative]::OPEN_EXISTING)
    $defaultOpen = $writer.Accepted
    $defaultWrite = $null
    if ($defaultOpen) { $defaultWrite = [DrTxCandidateNative]::Write($writer.Handle, 88) }
    Write-Observation 'default-stream-while-held' @{ open_accepted=$defaultOpen; open_win32_error=$writer.Error; write_accepted=($defaultWrite -eq 0); write_hresult=$defaultWrite; access='FILE_WRITE_DATA(0x2)'; share='READ|WRITE|DELETE(0x7)'; disposition='OPEN_EXISTING' }
    if ($defaultWrite -eq 0) { $limits.Add('default-content-written') }
    $writer.Handle.Dispose(); $writer = $null
    $heldChild.Dispose(); $heldChild = $null
    Close-Transaction $read $tx; $read = $null; $tx = $null
    $guard.Assert($fixture.base_id, $fixture.root_id)
    if ($adsOpen) {
        $rejected = $false
        try { $null = $guard.ContentIndex() } catch { $rejected = $_.Exception.ToString().Contains('unindexed named stream') }
        Assert-True $rejected 'Production content index accepted an unindexed ADS.'
    } else { $null = Assert-Index $guard 1 }
    if ($defaultWrite -eq 0) { $expected[0].bytes = [byte[]](88,65,83,69) }
    else { $expected[0].bytes = $original }
    Assert-FileBytes $file $expected[0].bytes
    if ($adsOpen) {
        $adsExpected = [byte[]]@()
        if ($adsWrite -eq 0) { $adsExpected = [byte[]](65) }
        Assert-FileBytes $ads $adsExpected
        $expected.Add([pscustomobject]@{path=$ads; bytes=$adsExpected})
    }
    $control = $file + ':after-release'
    $writer = [DrTxCandidateNative]::Writer($control, [DrTxCandidateNative]::CREATE_NEW)
    Write-Observation 'ads-after-release-control' @{ accepted=$writer.Accepted; native_error=$writer.Error; access='FILE_WRITE_DATA(0x2)'; share='READ|WRITE|DELETE(0x7)'; disposition='CREATE_NEW' }
    Assert-True $writer.Accepted 'ADS support after TxF/child release was not demonstrated.'
    $writeError = [DrTxCandidateNative]::Write($writer.Handle, 66)
    Assert-True ($writeError -eq 0) 'ADS after-release control write failed.'
    $expected.Add([pscustomobject]@{path=$control; bytes=[byte[]](66)})
    $writer.Handle.Dispose(); $writer = $null
    $guard.Dispose(); $guard = $null

    # A writer already open before TxF is a separate acquisition/real-write case.
    $fixture = New-Fixture 'existing-writer'
    $file = Join-Path $fixture.path 'content.txt'
    [IO.File]::WriteAllBytes($file, $original)
    $expected.Add([pscustomobject]@{path=$file; bytes=$original})
    $guard = New-Guard $fixture
    $null = Assert-Index $guard 1
    $writer = [DrTxCandidateNative]::Writer($file, [DrTxCandidateNative]::OPEN_EXISTING)
    Write-Observation 'existing-writer-open' @{ accepted=$writer.Accepted; native_error=$writer.Error; access='FILE_WRITE_DATA(0x2)'; share='READ|WRITE|DELETE(0x7)'; disposition='OPEN_EXISTING' }
    Assert-True $writer.Accepted 'Existing compatible writer could not be opened before TxF.'
    $tx = [DrTxCandidateNative]::Begin()
    Assert-True $tx.Accepted "Second CreateTransaction failed: $($tx.Error)"
    $read = [DrTxCandidateNative]::TxRead($file, $tx.Handle)
    Write-Observation 'tx-after-existing-writer' @{ accepted=$read.Accepted; native_error=$read.Error; access='FILE_READ_DATA(0x1)'; share='READ|WRITE|DELETE(0x7)'; existing_writer_access='FILE_WRITE_DATA(0x2)' }
    if (-not $read.Accepted) { $limits.Add('existing-writer-prevents-tx-acquisition') }
    $writeError = [DrTxCandidateNative]::Write($writer.Handle, 67)
    Write-Observation 'existing-writer-real-write' @{ accepted=($writeError -eq 0); native_or_hresult=$writeError; tx_read_accepted=$read.Accepted }
    if ($writeError -eq 0 -and $read.Accepted) { $limits.Add('existing-writer-wrote-during-tx') }
    $writer.Handle.Dispose(); $writer = $null
    Close-Transaction $read $tx; $read = $null; $tx = $null
    if ($writeError -eq 0) { $expected[$expected.Count - 1].bytes = [byte[]](67,65,83,69) }
    else { $expected[$expected.Count - 1].bytes = $original }
    Assert-FileBytes $file $expected[$expected.Count - 1].bytes
    $guard.Assert($fixture.base_id, $fixture.root_id)
    $null = Assert-Index $guard 1
    $guard.Dispose(); $guard = $null
    $tx = [DrTxCandidateNative]::Begin()
    Assert-True $tx.Accepted 'After-writer transaction acquisition failed.'
    $read = [DrTxCandidateNative]::TxRead($file, $tx.Handle)
    Write-Observation 'tx-after-existing-writer-release-control' @{ accepted=$read.Accepted; native_error=$read.Error; access='FILE_READ_DATA(0x1)'; share='READ|WRITE|DELETE(0x7)' }
    Assert-True $read.Accepted 'After-writer transacted read control failed.'
    Close-Transaction $read $tx; $read = $null; $tx = $null

    # Directory name changes are measured while a production root and a
    # transacted file read are live. No transacted directory writer is requested.
    $fixture = New-Fixture 'rename'
    $file = Join-Path $fixture.path 'content.txt'
    $renamed = Join-Path $fixture.path 'renamed.txt'
    [IO.File]::WriteAllBytes($file, $original)
    $expected.Add([pscustomobject]@{path=$file; bytes=$original})
    $guard = New-Guard $fixture
    $null = Assert-Index $guard 1
    $tx = [DrTxCandidateNative]::Begin(); Assert-True $tx.Accepted 'Rename transaction creation failed.'
    $read = [DrTxCandidateNative]::TxRead($file, $tx.Handle)
    Assert-True $read.Accepted "Rename fixture transacted read failed: $($read.Error)"
    $renameError = [DrTxCandidateNative]::Rename($file, $renamed)
    Write-Observation 'rename-while-held' @{ accepted=($renameError -eq 0); native_error=$renameError; flags='MoveFileExW(0)'; guard_root='READ_ATTRIBUTES|LIST_DIRECTORY|READ_CONTROL|DELETE|SYNCHRONIZE;SHARE_READ'; tx_read_access='FILE_READ_DATA(0x1)' }
    if ($renameError -eq 0) {
        $limits.Add('rename-succeeded')
        $expected[$expected.Count - 1].path = $renamed
    }
    Close-Transaction $read $tx; $read = $null; $tx = $null
    $guard.Assert($fixture.base_id, $fixture.root_id)
    $null = Assert-Index $guard 1
    $guard.Dispose(); $guard = $null

    $fixture = New-Fixture 'replacement'
    $file = Join-Path $fixture.path 'content.txt'
    $incoming = Join-Path $fixture.path 'incoming.txt'
    $replacement = [byte[]](82, 69, 80, 76)
    [IO.File]::WriteAllBytes($file, $original)
    [IO.File]::WriteAllBytes($incoming, $replacement)
    $expected.Add([pscustomobject]@{path=$file; bytes=$original})
    $expected.Add([pscustomobject]@{path=$incoming; bytes=$replacement})
    $guard = New-Guard $fixture
    $null = Assert-Index $guard 2
    $tx = [DrTxCandidateNative]::Begin(); Assert-True $tx.Accepted 'Replacement transaction creation failed.'
    $read = [DrTxCandidateNative]::TxRead($file, $tx.Handle)
    Assert-True $read.Accepted "Replacement fixture transacted read failed: $($read.Error)"
    $replaceError = [DrTxCandidateNative]::Replace($incoming, $file)
    Write-Observation 'replacement-while-held' @{ accepted=($replaceError -eq 0); native_error=$replaceError; flags='MoveFileExW(MOVEFILE_REPLACE_EXISTING=0x1)'; guard_root='READ_ATTRIBUTES|LIST_DIRECTORY|READ_CONTROL|DELETE|SYNCHRONIZE;SHARE_READ'; tx_read_access='FILE_READ_DATA(0x1)'; original_content_replaced=($replaceError -eq 0) }
    if ($replaceError -eq 0) {
        $limits.Add('original-content-replaced')
        $expected[$expected.Count - 2].bytes = $replacement
        $expected.RemoveAt($expected.Count - 1)
    }
    Close-Transaction $read $tx; $read = $null; $tx = $null
    $guard.Assert($fixture.base_id, $fixture.root_id)
    $null = Assert-Index $guard $(if ($replaceError -eq 0) { 1 } else { 2 })
    $guard.Dispose(); $guard = $null

    $fixture = New-Fixture 'namespace'
    $file = Join-Path $fixture.path 'content.txt'
    $child = Join-Path $fixture.path 'new-child.txt'
    [IO.File]::WriteAllBytes($file, $original)
    $expected.Add([pscustomobject]@{path=$file; bytes=$original})
    $guard = New-Guard $fixture
    $null = Assert-Index $guard 1
    $tx = [DrTxCandidateNative]::Begin(); Assert-True $tx.Accepted 'Namespace transaction creation failed.'
    $read = [DrTxCandidateNative]::TxRead($file, $tx.Handle)
    Assert-True $read.Accepted "Namespace fixture transacted read failed: $($read.Error)"
    $directoryRead = [DrTxCandidateNative]::TxDirectoryRead($fixture.path, $tx.Handle)
    Write-Observation 'tx-directory-read-while-held' @{ accepted=$directoryRead.Accepted; native_error=$directoryRead.Error; access='FILE_LIST_DIRECTORY(0x1)'; share='READ|WRITE|DELETE(0x7)'; disposition='OPEN_EXISTING'; flags='FILE_FLAG_BACKUP_SEMANTICS(0x02000000)' }
    if (-not $directoryRead.Accepted) { $limits.Add('read-only-tx-directory-acquisition-failed') }
    $writer = [DrTxCandidateNative]::Writer($child, [DrTxCandidateNative]::CREATE_NEW)
    $childOpen = $writer.Accepted
    Write-Observation 'new-child-while-held' @{ open_accepted=$childOpen; open_win32_error=$writer.Error; access='FILE_WRITE_DATA(0x2)'; share='READ|WRITE|DELETE(0x7)'; disposition='CREATE_NEW'; guard_root='READ_ATTRIBUTES|LIST_DIRECTORY|READ_CONTROL|DELETE|SYNCHRONIZE;SHARE_READ'; tx_directory_read_accepted=$directoryRead.Accepted }
    Assert-True $childOpen 'Expected namespace gap was not observed; investigate rather than admitting Gate 1.'
    $limits.Add('new-child-created')
    $writeError = [DrTxCandidateNative]::Write($writer.Handle, 68)
    Write-Observation 'new-child-write' @{ accepted=($writeError -eq 0); write_hresult=$writeError }
    $writer.Handle.Dispose(); $writer = $null
    $guard.Assert($fixture.base_id, $fixture.root_id)
    $null = Assert-Index $guard 2
    Close-Transaction $read $tx $directoryRead; $read = $null; $tx = $null; $directoryRead = $null
    $childBytes = [byte[]]@()
    if ($writeError -eq 0) { $childBytes = [byte[]](68) }
    Assert-FileBytes $child $childBytes # Rollback must not erase the nontransacted addition.
    $expected.Add([pscustomobject]@{path=$child; bytes=$childBytes})
    Write-Observation 'new-child-after-rollback' @{ exists=$true; bytes=$childBytes.Length; write_accepted=($writeError -eq 0) }
    $guard.Dispose(); $guard = $null

    # An abort before final verification retains all disposable fixtures.
    # Even a verified fixture is retained: the root handle cannot exclude a
    # late new child, so recursive pathname cleanup would risk removing it.
    foreach ($item in $expected) { Assert-FileBytes $item.path $item.bytes }
    foreach ($item in $fixtures) {
        $actualNames = @([IO.Directory]::EnumerateFileSystemEntries($item.path) |
            ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object -CaseSensitive)
        $expectedNames = @($expected | Where-Object {
            [IO.Path]::GetDirectoryName($_.path) -ceq $item.path
        } | ForEach-Object { [IO.Path]::GetFileName($_.path).Split(':')[0] } |
            Sort-Object -Unique -CaseSensitive)
        Assert-True (($actualNames -join '|') -ceq ($expectedNames -join '|')) `
            'Owned fixture directory membership changed before cleanup.'
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($item.path)) {
            Assert-True (-not ([IO.File]::GetAttributes($entry) -band [IO.FileAttributes]::ReparsePoint)) `
                'Owned fixture gained a reparse entry before cleanup.'
        }
        $guard = New-Guard $item
        $guard.Assert($item.base_id, $item.root_id)
        $guard.Dispose(); $guard = $null
    }
    Write-Observation 'gate1-result' @{ gate='BLOCKED'; mechanism='TxF read plus production owned root guard'; observed_candidate_limits=@($limits.ToArray()); target_collection=0; disposition=0; product=0; verified_fixture_streams=$expected.Count; fixture_disposition='retained'; delete_attempts=0; helper_processes=0; timeout_observation='not-run'; collector_death_observation='not-run'; safe_disposition_sequence='not-tested' }
    $complete = $true
}
finally {
    if ($null -ne $writer -and $null -ne $writer.Handle) { $writer.Handle.Dispose() }
    if ($null -ne $heldChild) { $heldChild.Dispose() }
    if ($null -ne $read -or $null -ne $tx -or $null -ne $directoryRead) {
        Close-Transaction $read $tx $directoryRead
    }
    if ($null -ne $guard) { $guard.Dispose() }
    Write-Observation 'fixture-preserved' @{ gate='BLOCKED'; target_collection=0; disposition=0; product=0; fixture_count=$fixtures.Count; verification_complete=$complete; delete_attempts=0; reason=$(if ($complete) { 'blocked-candidate-keeps-fixtures' } else { 'incomplete-or-unexpected-observation' }) }
}
