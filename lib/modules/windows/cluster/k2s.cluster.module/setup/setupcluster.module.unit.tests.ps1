# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

Describe 'Wait-KubeadmJoinProcess' -Tag 'unit', 'ci', 'cluster' {
BeforeAll {
    $modulePath = "$PSScriptRoot/setupcluster.module.psm1"
    $parseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
    $waitFunction = $moduleAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-KubeadmJoinProcess'
    }, $false)
    . ([scriptblock]::Create($waitFunction.Extent.Text))

    $script:kubeToolsPath = 'C:\k'
    function Write-Log { param($Message, [switch]$Console) }
    function Stop-Process { [CmdletBinding()] param($Id, [switch]$Force) }
    function Get-Service { [CmdletBinding()] param($Name) }
}

    BeforeEach {
        Mock Write-Log {}
        Mock Stop-Process {}
        Mock Get-Service {}
    }

    It 'returns the process exit code when kubeadm finishes in time' {
        $process = [pscustomobject]@{
            Handle = [intptr]::Zero
            Id = 42
            ExitCode = 0
        }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds) return $true }

        $result = Wait-KubeadmJoinProcess -Process $process -StandardOutputPath 'missing.stdout' -StandardErrorPath 'missing.stderr'

        $result | Should -Be 0
        Should -Invoke Stop-Process -Times 0 -Exactly
    }

    It 'terminates only the timed-out kubeadm process and throws' {
        $process = [pscustomobject]@{
            Handle = [intptr]::Zero
            Id = 73
            ExitCode = -1
        }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            param($milliseconds)
            if ($null -eq $milliseconds) { return }
            return $false
        }

        {
            Wait-KubeadmJoinProcess -Process $process -StandardOutputPath 'missing.stdout' `
                -StandardErrorPath 'missing.stderr' -TimeoutSeconds 1
        } | Should -Throw '*timed out after 1 seconds*'

        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 73 -and $Force }
    }
}

BeforeDiscovery {
    $script:kubectlMissing = -not (Test-Path ([System.IO.Path]::GetFullPath("$PSScriptRoot\..\..\..\..\..\..\bin\kube\kubectl.exe")))
}

# Shared fixtures for the Add-K8sContext suites. Everything runs in an isolated temp profile;
# the real %USERPROFILE%\.kube is never touched. This file must stay ASCII-only (PS 5.1 reads
# BOM-less scripts as ANSI), so non-ASCII names are built from code points.
BeforeAll {
    $modulePath = "$PSScriptRoot/setupcluster.module.psm1"
    $parseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
    $kubeconfigFunctionNames = @(
        'Add-K8sContext', 'ConvertTo-KubectlArgumentString', 'Invoke-KubeconfigKubectl', 'Invoke-KubeconfigKubectlChecked',
        'Assert-KubeconfigBytes', 'Get-KubeconfigObject', 'Get-KubeconfigNamedEntries', 'Assert-MergedKubeconfig',
        'Write-KubeconfigStagingFile', 'Publish-KubeconfigFile')
    $kubeconfigFunctions = $moduleAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $kubeconfigFunctionNames -contains $node.Name
        }, $false)
    foreach ($function in $kubeconfigFunctions) {
        . ([scriptblock]::Create($function.Extent.Text))
    }
    $script:realWriteKubeconfigStagingFile = ${function:Write-KubeconfigStagingFile}

    function Write-Log { param($Message, [switch]$Console) }
    function Get-InstalledClusterName { 'k2s-cluster' }

    $script:realKubectlExe = [System.IO.Path]::GetFullPath("$PSScriptRoot\..\..\..\..\..\..\bin\kube\kubectl.exe")
    $script:utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $script:k2sContextName = 'kubernetes-admin@k2s-cluster'

    function New-Base64Data([int]$Seed, [int]$Length) {
        $random = New-Object System.Random($Seed)
        $buffer = New-Object byte[] $Length
        $random.NextBytes($buffer)
        return [Convert]::ToBase64String($buffer)
    }
    $eAcute = [string][char]0x00E9
    $uUmlaut = [string][char]0x00FC
    $oUmlaut = [string][char]0x00F6
    $tokyo = [string][char]0x6771 + [char]0x4EAC
    $script:aksClusterName = "aks-prod-m${uUmlaut}nchen"
    $script:aksUserName = "clusterUser_rg_j${oUmlaut}rg"
    $script:aksContextName = "aks-${eAcute}quipe@$tokyo"
    $script:aksNamespace = "team-${uUmlaut}${oUmlaut}${eAcute}"

    function New-K2sCluster([int]$Seed) {
        [ordered]@{ name = 'k2s-cluster'; cluster = [ordered]@{ 'certificate-authority-data' = (New-Base64Data -Seed $Seed -Length 1100); server = 'https://172.19.1.100:6443' } }
    }
    function New-K2sUser([int]$Seed) {
        [ordered]@{ name = 'kubernetes-admin'; user = [ordered]@{ 'client-certificate-data' = (New-Base64Data -Seed ($Seed + 1) -Length 1150); 'client-key-data' = (New-Base64Data -Seed ($Seed + 2) -Length 1680) } }
    }
    function New-K2sContext {
        [ordered]@{ name = $script:k2sContextName; context = [ordered]@{ cluster = 'k2s-cluster'; user = 'kubernetes-admin' } }
    }
    function New-ForeignClusters {
        @(
            [ordered]@{ name = 'docker-desktop'; cluster = [ordered]@{ 'certificate-authority-data' = (New-Base64Data -Seed 40 -Length 600); server = 'https://kubernetes.docker.internal:6443' } },
            [ordered]@{ name = $script:aksClusterName; cluster = [ordered]@{ 'certificate-authority-data' = (New-Base64Data -Seed 41 -Length 600); server = 'https://aks-prod.hcp.westeurope.azmk8s.io:443' } }
        )
    }
    function New-ForeignUsers {
        @(
            [ordered]@{ name = 'docker-desktop'; user = [ordered]@{ 'client-certificate-data' = (New-Base64Data -Seed 42 -Length 700); 'client-key-data' = (New-Base64Data -Seed 43 -Length 900) } },
            [ordered]@{ name = $script:aksUserName; user = [ordered]@{ exec = [ordered]@{ apiVersion = 'client.authentication.k8s.io/v1beta1'; command = 'kubelogin'; args = @('get-token', '--login', 'azurecli', '--server-id', '6dae42f8-4368-4678-94ff-3960e28e3630'); interactiveMode = 'IfAvailable'; provideClusterInfo = $false } } }
        )
    }
    function New-ForeignContexts {
        @(
            [ordered]@{ name = 'docker-desktop'; context = [ordered]@{ cluster = 'docker-desktop'; user = 'docker-desktop' } },
            [ordered]@{ name = $script:aksContextName; context = [ordered]@{ cluster = $script:aksClusterName; namespace = $script:aksNamespace; user = $script:aksUserName } }
        )
    }

    # Kubeconfig fixtures are written as JSON, which is valid YAML for kubectl and readable by the fake kubectl.
    function New-KubeconfigText {
        param([object[]]$Clusters = @(), [object[]]$Users = @(), [object[]]$Contexts = @(), [string]$CurrentContext = '')
        $config = [ordered]@{
            apiVersion        = 'v1'
            kind              = 'Config'
            preferences       = [ordered]@{}
            clusters          = @($Clusters)
            users             = @($Users)
            contexts          = @($Contexts)
            'current-context' = $CurrentContext
        }
        return ($config | ConvertTo-Json -Depth 32)
    }
    function New-K2sSourceText([int]$Seed = 1) {
        New-KubeconfigText -Clusters @(New-K2sCluster $Seed) -Users @(New-K2sUser $Seed) -Contexts @(New-K2sContext) -CurrentContext $script:k2sContextName
    }
    function New-UserKubeconfigText([string]$CurrentContext, [switch]$IncludeStaleK2s) {
        $clusters = @(New-ForeignClusters)
        $users = @(New-ForeignUsers)
        $contexts = @(New-ForeignContexts)
        if ($IncludeStaleK2s) {
            # Stale K2s entries (old certificates) interleaved between foreign entries.
            $clusters = @($clusters[0], (New-K2sCluster 900), $clusters[1])
            $users = @($users[0], (New-K2sUser 900), $users[1])
            $contexts = @($contexts[0], (New-K2sContext), $contexts[1])
        }
        New-KubeconfigText -Clusters $clusters -Users $users -Contexts $contexts -CurrentContext $CurrentContext
    }

    function Write-TestFile([string]$Path, [string]$Content, [System.Text.Encoding]$Encoding = $script:utf8NoBom) {
        [System.IO.File]::WriteAllText($Path, $Content, $Encoding)
    }
    function Get-FileBase64([string]$Path) {
        [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path))
    }

    function Initialize-KubeconfigTestProfile {
        $script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-kubeconfig-test-$([guid]::NewGuid().ToString('N'))"
        $script:kubePath = Join-Path $script:testRoot 'k2s'
        $script:kubeConfigDir = Join-Path $script:testRoot 'profile\.kube'
        $script:userKubeconfig = Join-Path $script:kubeConfigDir 'config'
        $script:backupKubeconfig = Join-Path $script:kubeConfigDir 'config_backup'
        $script:k2sSourcePath = Join-Path $script:kubePath 'config'
        New-Item -ItemType Directory -Path $script:kubePath -Force | Out-Null
        Write-TestFile -Path $script:k2sSourcePath -Content (New-K2sSourceText)
        $script:savedEnv = @{ KUBECONFIG = $env:KUBECONFIG; HOME = $env:HOME; USERPROFILE = $env:USERPROFILE }
        $env:HOME = Join-Path $script:testRoot 'profile'
        $env:USERPROFILE = $env:HOME
        $env:KUBECONFIG = $null
    }
    function Remove-KubeconfigTestProfile {
        $env:KUBECONFIG = $script:savedEnv.KUBECONFIG
        $env:HOME = $script:savedEnv.HOME
        $env:USERPROFILE = $script:savedEnv.USERPROFILE
        if (Test-Path $script:userKubeconfig) { (Get-Item $script:userKubeconfig).IsReadOnly = $false }
        Remove-Item -Path $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    function Initialize-ExistingUserKubeconfig([string]$Content, [System.Text.Encoding]$Encoding = $script:utf8NoBom) {
        New-Item -ItemType Directory -Path $script:kubeConfigDir -Force | Out-Null
        Write-TestFile -Path $script:userKubeconfig -Content $Content -Encoding $Encoding
        Write-TestFile -Path $script:backupKubeconfig -Content 'previous backup'
        $script:originalUserBytes = Get-FileBase64 $script:userKubeconfig
        $script:originalBackupBytes = Get-FileBase64 $script:backupKubeconfig
    }

    function Assert-NoTemporaryFiles {
        $leftovers = @(Get-ChildItem -LiteralPath $script:kubeConfigDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('config', 'config_backup') })
        $leftovers.Name | Should -BeNullOrEmpty -Because 'staging, working and lock files must be cleaned up'
    }
    function Assert-UserKubeconfigUnchanged {
        Get-FileBase64 $script:userKubeconfig | Should -BeExactly $script:originalUserBytes -Because 'the user kubeconfig must stay byte-for-byte unchanged'
        Get-FileBase64 $script:backupKubeconfig | Should -BeExactly $script:originalBackupBytes -Because 'config_backup must not be touched when nothing was committed'
        Assert-NoTemporaryFiles
        $env:KUBECONFIG | Should -BeNullOrEmpty
    }

    function Assert-PortableKubeconfigBytes([byte[]]$Bytes) {
        $Bytes.Length | Should -BeGreaterThan 0
        ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) | Should -BeFalse -Because 'UTF-16LE BOM must not be written'
        ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) | Should -BeFalse -Because 'UTF-16BE BOM must not be written'
        ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) | Should -BeFalse -Because 'UTF-8 BOM must not be written'
        [array]::IndexOf($Bytes, [byte]0) | Should -Be -1 -Because 'kubeconfig must not contain NUL bytes'
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($Bytes)
        $text.Contains([string][char]0) | Should -BeFalse
        return $text
    }

    function Get-EntryJson($Config, [string]$Section, [string]$Name) {
        $matching = @($Config.$Section | Where-Object { $null -ne $_ -and $_.name -ceq $Name })
        $matching.Count | Should -Be 1 -Because "exactly one $Section entry '$Name' is expected"
        return ($matching[0] | ConvertTo-Json -Compress -Depth 64)
    }

    # Verifies the committed user kubeconfig: encoding, K2s entries from the source, foreign entries unchanged, no extras.
    function Assert-UpdatedUserKubeconfig {
        param([string]$KubectlPath, $OriginalParsed, [string[]]$ForeignContexts = @(), [string[]]$ForeignClusters = @(), [string[]]$ForeignUsers = @())
        Assert-PortableKubeconfigBytes -Bytes ([System.IO.File]::ReadAllBytes($script:userKubeconfig)) | Out-Null
        $result = Get-KubeconfigObject -KubectlPath $KubectlPath -Path $script:userKubeconfig
        $source = Get-KubeconfigObject -KubectlPath $KubectlPath -Path $script:k2sSourcePath
        $result.'current-context' | Should -BeExactly $script:k2sContextName
        Get-EntryJson $result 'clusters' 'k2s-cluster' | Should -BeExactly (Get-EntryJson $source 'clusters' 'k2s-cluster')
        Get-EntryJson $result 'users' 'kubernetes-admin' | Should -BeExactly (Get-EntryJson $source 'users' 'kubernetes-admin')
        Get-EntryJson $result 'contexts' $script:k2sContextName | Should -BeExactly (Get-EntryJson $source 'contexts' $script:k2sContextName)
        foreach ($name in $ForeignClusters) { Get-EntryJson $result 'clusters' $name | Should -BeExactly (Get-EntryJson $OriginalParsed 'clusters' $name) }
        foreach ($name in $ForeignUsers) { Get-EntryJson $result 'users' $name | Should -BeExactly (Get-EntryJson $OriginalParsed 'users' $name) }
        foreach ($name in $ForeignContexts) { Get-EntryJson $result 'contexts' $name | Should -BeExactly (Get-EntryJson $OriginalParsed 'contexts' $name) }
        @($result.clusters).Count | Should -Be ($ForeignClusters.Count + 1)
        @($result.users).Count | Should -Be ($ForeignUsers.Count + 1)
        @($result.contexts).Count | Should -Be ($ForeignContexts.Count + 1)
        return $result
    }

    $script:foreignContextNames = @('docker-desktop', $script:aksContextName)
    $script:foreignClusterNames = @('docker-desktop', $script:aksClusterName)
    $script:foreignUserNames = @('docker-desktop', $script:aksUserName)
}

# Unit suite: kubectl is replaced by an in-process fake (JSON kubeconfigs), so it runs in CI
# without bin\kube\kubectl.exe. Faults are injected at every stage of Add-K8sContext.
Describe 'Add-K8sContext safe kubeconfig merge (fake kubectl)' -Tag 'unit', 'ci', 'cluster' {
    BeforeAll {
        $script:fakeKubectlPath = 'C:\fake\kubectl.exe'

        function Read-FakeKubeconfig([string]$Path) {
            $empty = [pscustomobject][ordered]@{ kind = 'Config'; apiVersion = 'v1'; clusters = $null; users = $null; contexts = $null; 'current-context' = '' }
            if (!(Test-Path -LiteralPath $Path)) { return $empty }
            $bytes = [System.IO.File]::ReadAllBytes($Path)
            if ($bytes.Length -eq 0) { return $empty }
            $reader = New-Object System.IO.StreamReader((New-Object System.IO.MemoryStream(, $bytes)), (New-Object System.Text.UTF8Encoding($false, $true)), $true)
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            if ($text.IndexOf([char]0) -ge 0) { throw 'null byte is not allowed in input' }
            return ($text | ConvertFrom-Json)
        }
        function Write-FakeKubeconfig([string]$Path, $Config) {
            [System.IO.File]::WriteAllText($Path, ($Config | ConvertTo-Json -Depth 64), $script:utf8NoBom)
        }
        function New-FakeResult([int]$ExitCode, [byte[]]$StdOut = @(), [string]$StdErr = '') {
            [pscustomobject]@{ ExitCode = $ExitCode; StdOut = [byte[]]$StdOut; StdErr = $StdErr }
        }

        function Invoke-FakeKubectl([string[]]$Arguments, [string]$KubeConfig) {
            $script:kubectlCalls.Add([pscustomobject]@{ Arguments = $Arguments; KubeConfig = $KubeConfig })
            $fault = $script:fault
            $faultHit = ($null -ne $fault) -and (& $fault.Match $Arguments $KubeConfig)
            if ($faultHit -and $fault.Mode -eq 'fail') { return (New-FakeResult -ExitCode 1 -StdErr 'injected kubectl failure') }
            if ($faultHit -and $fault.Mode -eq 'empty') { return (New-FakeResult -ExitCode 0) }
            $kubeconfigArg = $null
            for ($i = 0; $i -lt $Arguments.Count - 1; $i++) { if ($Arguments[$i] -eq '--kubeconfig') { $kubeconfigArg = $Arguments[$i + 1] } }
            try {
                $verb = $Arguments[1]
                if ($verb -eq 'view') {
                    if ($kubeconfigArg) {
                        $config = Read-FakeKubeconfig $kubeconfigArg
                    }
                    else {
                        $merged = [ordered]@{ apiVersion = 'v1'; kind = 'Config'; clusters = @(); users = @(); contexts = @(); 'current-context' = '' }
                        foreach ($file in @($KubeConfig -split ';' | Where-Object { $_ })) {
                            $part = Read-FakeKubeconfig $file
                            foreach ($section in @('clusters', 'users', 'contexts')) {
                                foreach ($entry in @($part.$section | Where-Object { $null -ne $_ })) {
                                    if (@($merged[$section] | Where-Object { $_.name -ceq $entry.name }).Count -eq 0) { $merged[$section] = @($merged[$section]) + $entry }
                                }
                            }
                            if ([string]::IsNullOrEmpty($merged['current-context']) -and $part.'current-context') { $merged['current-context'] = $part.'current-context' }
                        }
                        if ($faultHit -and $fault.Mode -eq 'dropForeign') { $merged['contexts'] = @($merged['contexts'] | Where-Object { $_.name -cne 'docker-desktop' }) }
                        $config = [pscustomobject]$merged
                    }
                    $text = ($config | ConvertTo-Json -Depth 64) + "`n"
                    if ($faultHit -and $fault.Mode -eq 'utf16') { return (New-FakeResult -ExitCode 0 -StdOut ([System.Text.Encoding]::Unicode.GetPreamble() + [System.Text.Encoding]::Unicode.GetBytes($text))) }
                    $bytes = $script:utf8NoBom.GetBytes($text)
                    if ($faultHit -and $fault.Mode -eq 'nul') { $bytes = $bytes + [byte]0 }
                    return (New-FakeResult -ExitCode 0 -StdOut $bytes)
                }
                $config = Read-FakeKubeconfig $kubeconfigArg
                $name = $Arguments[2]
                $sectionByVerb = @{ 'delete-context' = 'contexts'; 'delete-cluster' = 'clusters'; 'delete-user' = 'users' }
                if ($sectionByVerb.ContainsKey($verb)) {
                    $section = $sectionByVerb[$verb]
                    if (@($config.$section | Where-Object { $null -ne $_ -and $_.name -ceq $name }).Count -eq 0) { return (New-FakeResult -ExitCode 1 -StdErr "cannot delete $name") }
                    $config.$section = @($config.$section | Where-Object { $null -ne $_ -and $_.name -cne $name })
                }
                elseif ($verb -eq 'use-context') {
                    if (@($config.contexts | Where-Object { $null -ne $_ -and $_.name -ceq $name }).Count -eq 0) { return (New-FakeResult -ExitCode 1 -StdErr "no context exists with the name: $name") }
                    $config.'current-context' = $name
                }
                else {
                    return (New-FakeResult -ExitCode 1 -StdErr "unsupported fake command: $($Arguments -join ' ')")
                }
                Write-FakeKubeconfig $kubeconfigArg $config
                return (New-FakeResult -ExitCode 0)
            }
            catch {
                return (New-FakeResult -ExitCode 1 -StdErr "error loading config: $($_.Exception.Message)")
            }
        }
    }

    BeforeEach {
        Initialize-KubeconfigTestProfile
        $script:kubeToolsPath = Split-Path $script:fakeKubectlPath -Parent
        $script:fault = $null
        $script:kubectlCalls = New-Object System.Collections.Generic.List[object]
        Mock Invoke-KubeconfigKubectl { Invoke-FakeKubectl -Arguments $Arguments -KubeConfig $KubeConfig }
    }

    AfterEach {
        Remove-KubeconfigTestProfile
    }

    It 'never runs a mutating kubectl command against the user kubeconfig' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:k2sContextName -IncludeStaleK2s)

        Add-K8sContext

        $mutating = @($script:kubectlCalls | Where-Object { $_.Arguments[1] -notin @('view') })
        $mutating.Count | Should -BeGreaterThan 0
        foreach ($call in $mutating) {
            $call.Arguments | Should -Not -Contain $script:userKubeconfig
            $call.KubeConfig | Should -BeNullOrEmpty
        }
        @($script:kubectlCalls | Where-Object { $_.KubeConfig }) | ForEach-Object { ($_.KubeConfig -split ';') | Should -Not -Contain $script:userKubeconfig }
    }

    It 'fresh install creates a validated kubeconfig with the K2s context' {
        Add-K8sContext

        Assert-UpdatedUserKubeconfig -KubectlPath $script:fakeKubectlPath | Out-Null
        Test-Path $script:backupKubeconfig | Should -BeFalse
        Assert-NoTemporaryFiles
    }

    It 'replaces stale K2s entries, preserves foreign entries and keeps the original as config_backup (current context: <Current>)' -ForEach @(
        @{ Current = 'k2s' }, @{ Current = 'foreign' }
    ) {
        $current = if ($Current -eq 'k2s') { $script:k2sContextName } else { $script:aksContextName }
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $current -IncludeStaleK2s)
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:fakeKubectlPath -Path $script:userKubeconfig

        Add-K8sContext

        Assert-UpdatedUserKubeconfig -KubectlPath $script:fakeKubectlPath -OriginalParsed $originalParsed `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames | Out-Null
        Get-FileBase64 $script:backupKubeconfig | Should -BeExactly $script:originalUserBytes
        Assert-NoTemporaryFiles
    }

    It 'repairs a UTF-16LE kubeconfig without losing entries' {
        Initialize-ExistingUserKubeconfig -Content ((New-UserKubeconfigText -CurrentContext $script:k2sContextName -IncludeStaleK2s) -replace "`r?`n", "`r`n") -Encoding ([System.Text.Encoding]::Unicode)
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:fakeKubectlPath -Path $script:userKubeconfig

        Add-K8sContext

        Assert-UpdatedUserKubeconfig -KubectlPath $script:fakeKubectlPath -OriginalParsed $originalParsed `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames | Out-Null
    }

    It 'repeated execution and certificate renewal stay deterministic without duplicates' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName)
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:fakeKubectlPath -Path $script:userKubeconfig

        Add-K8sContext
        $first = Get-FileBase64 $script:userKubeconfig
        Add-K8sContext
        Get-FileBase64 $script:userKubeconfig | Should -BeExactly $first

        # Renewal: same function, new K2s certificates in '<install>\config'.
        Write-TestFile -Path $script:k2sSourcePath -Content (New-K2sSourceText -Seed 77)
        Add-K8sContext
        Assert-UpdatedUserKubeconfig -KubectlPath $script:fakeKubectlPath -OriginalParsed $originalParsed `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames | Out-Null
        Get-FileBase64 $script:userKubeconfig | Should -Not -BeExactly $first
        Assert-NoTemporaryFiles
    }

    It 'leaves the user kubeconfig byte-for-byte unchanged when <Stage> fails' -ForEach @(
        @{ Stage = 'parsing the K2s kubeconfig'; Mode = 'fail'; Match = { param($a, $k) $a[1] -eq 'view' -and $a[-1] -like '*\k2s\config' } }
        @{ Stage = 'parsing the user kubeconfig'; Mode = 'fail'; Match = { param($a, $k) $a[1] -eq 'view' -and $a[-1] -like '*\.kube\config' } }
        @{ Stage = 'kubectl config delete-context'; Mode = 'fail'; Match = { param($a, $k) $a[1] -eq 'delete-context' } }
        @{ Stage = 'kubectl config delete-cluster'; Mode = 'fail'; Match = { param($a, $k) $a[1] -eq 'delete-cluster' } }
        @{ Stage = 'kubectl config delete-user'; Mode = 'fail'; Match = { param($a, $k) $a[1] -eq 'delete-user' } }
        @{ Stage = 'merged config generation'; Mode = 'fail'; Match = { param($a, $k) $k -like '*;*' } }
        @{ Stage = 'merged config generation (empty output)'; Mode = 'empty'; Match = { param($a, $k) $k -like '*;*' } }
        @{ Stage = 'merged config generation (UTF-16 output)'; Mode = 'utf16'; Match = { param($a, $k) $k -like '*;*' } }
        @{ Stage = 'merged config generation (NUL byte)'; Mode = 'nul'; Match = { param($a, $k) $k -like '*;*' } }
        @{ Stage = 'merged config validation (foreign context lost)'; Mode = 'dropForeign'; Match = { param($a, $k) $k -like '*;*' } }
        @{ Stage = 'kubectl config use-context'; Mode = 'fail'; Match = { param($a, $k) $a[1] -eq 'use-context' } }
        @{ Stage = 'parsing the staged kubeconfig'; Mode = 'fail'; Match = { param($a, $k) $a[1] -eq 'view' -and $a[-1] -like '*.new' } }
        @{ Stage = 'parsing the staged kubeconfig (empty output)'; Mode = 'empty'; Match = { param($a, $k) $a[1] -eq 'view' -and $a[-1] -like '*.new' } }
    ) {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $script:fault = @{ Mode = $Mode; Match = $Match }

        { Add-K8sContext } | Should -Throw '*KubeConfig*'

        Assert-UserKubeconfigUnchanged
    }

    It 'leaves the user kubeconfig byte-for-byte unchanged when <Stage> fails' -ForEach @(
        @{ Stage = 'the staging-file write'; Command = 'Write-KubeconfigStagingFile' }
        @{ Stage = 'the final validation'; Command = 'Assert-MergedKubeconfig' }
        @{ Stage = 'the replacement'; Command = 'Publish-KubeconfigFile' }
    ) {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:k2sContextName -IncludeStaleK2s)
        Mock $Command { throw '[KubeConfig] injected failure' }

        { Add-K8sContext } | Should -Throw '*injected failure*'

        Assert-UserKubeconfigUnchanged
    }

    It 'keeps the original and cleans up when File.Replace is denied (read-only target)' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:k2sContextName -IncludeStaleK2s)
        (Get-Item $script:userKubeconfig).IsReadOnly = $true

        { Add-K8sContext } | Should -Throw '*denied*'

        Assert-UserKubeconfigUnchanged
    }

    It 'does not overwrite a kubeconfig that another process changed during the update' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:k2sContextName)
        $script:concurrent = New-UserKubeconfigText -CurrentContext 'docker-desktop'
        Mock Write-KubeconfigStagingFile {
            & $script:realWriteKubeconfigStagingFile -Path $Path -Bytes $Bytes
            Write-TestFile -Path $script:userKubeconfig -Content $script:concurrent
        }

        { Add-K8sContext } | Should -Throw '*modified by another process*'

        [System.IO.File]::ReadAllText($script:userKubeconfig) | Should -BeExactly $script:concurrent
        Get-FileBase64 $script:backupKubeconfig | Should -BeExactly $script:originalBackupBytes
        Assert-NoTemporaryFiles
    }

    It 'fails without creating a user kubeconfig when the K2s kubeconfig is <Case>' -ForEach @(
        @{ Case = 'missing' }, @{ Case = 'empty' }
    ) {
        if ($Case -eq 'missing') { Remove-Item $script:k2sSourcePath } else { Write-TestFile -Path $script:k2sSourcePath -Content '' }

        { Add-K8sContext } | Should -Throw '*missing or empty*'

        Test-Path $script:userKubeconfig | Should -BeFalse
    }

    It 'fails and keeps the user kubeconfig when the K2s kubeconfig is <Case>' -ForEach @(
        @{ Case = 'missing' }, @{ Case = 'empty' }
    ) {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:k2sContextName -IncludeStaleK2s)
        if ($Case -eq 'missing') { Remove-Item $script:k2sSourcePath } else { Write-TestFile -Path $script:k2sSourcePath -Content '' }

        { Add-K8sContext } | Should -Throw '*missing or empty*'

        Assert-UserKubeconfigUnchanged
    }

    It 'quotes native arguments with spaces, quotes and trailing backslashes' {
        ConvertTo-KubectlArgumentString -Arguments @('config', 'view', '--kubeconfig', 'C:\Users\J Doe\.kube\config') | Should -BeExactly 'config view --kubeconfig "C:\Users\J Doe\.kube\config"'
        ConvertTo-KubectlArgumentString -Arguments @('a"b', 'C:\dir with space\', '') | Should -BeExactly '"a\"b" "C:\dir with space\\" ""'
    }
}

# Integration suite: exercises Add-K8sContext with the real bin\kube\kubectl.exe (installed by the
# K2s setup / 'bgow' is not sufficient - kubectl.exe is downloaded during K2s installation). Not run
# by the CI unit job; run locally with -Tag integration.
Describe 'Add-K8sContext kubeconfig output (real kubectl)' -Tag 'integration', 'cluster' -Skip:$script:kubectlMissing {
    BeforeEach {
        Initialize-KubeconfigTestProfile
        $script:kubeToolsPath = Split-Path $script:realKubectlExe -Parent
    }

    AfterEach {
        Remove-KubeconfigTestProfile
    }

    It 'fresh install writes UTF-8 without BOM with the K2s context' {
        Add-K8sContext

        $text = Assert-PortableKubeconfigBytes -Bytes ([System.IO.File]::ReadAllBytes($script:userKubeconfig))
        $text.StartsWith('apiVersion:') | Should -BeTrue
        Assert-UpdatedUserKubeconfig -KubectlPath $script:realKubectlExe | Out-Null
        Assert-NoTemporaryFiles
    }

    It 'merge preserves Docker Desktop/AKS entries and updates stale K2s entries (current context: <Current>)' -ForEach @(
        @{ Current = 'k2s' }, @{ Current = 'foreign' }
    ) {
        $current = if ($Current -eq 'k2s') { $script:k2sContextName } else { $script:aksContextName }
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $current -IncludeStaleK2s)
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:realKubectlExe -Path $script:userKubeconfig

        Add-K8sContext

        $result = Assert-UpdatedUserKubeconfig -KubectlPath $script:realKubectlExe -OriginalParsed $originalParsed `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames
        ($result.contexts | Where-Object { $_.name -ceq $script:aksContextName }).context.namespace | Should -BeExactly $script:aksNamespace
        $text = [System.IO.File]::ReadAllText($script:userKubeconfig, $script:utf8NoBom)
        $text.Contains($script:aksContextName) | Should -BeTrue -Because 'non-ASCII names must be stored as UTF-8'
        Get-FileBase64 $script:backupKubeconfig | Should -BeExactly $script:originalUserBytes
        Assert-NoTemporaryFiles
    }

    It 'repairs a UTF-16LE kubeconfig written by earlier K2s versions' {
        Initialize-ExistingUserKubeconfig -Content ((New-UserKubeconfigText -CurrentContext $script:k2sContextName -IncludeStaleK2s) -replace "`r?`n", "`r`n") -Encoding ([System.Text.Encoding]::Unicode)
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:realKubectlExe -Path $script:userKubeconfig

        Add-K8sContext

        Assert-UpdatedUserKubeconfig -KubectlPath $script:realKubectlExe -OriginalParsed $originalParsed `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames | Out-Null
    }

    It 'preserves non-ASCII content regardless of the console output code page' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:k2sContextName -IncludeStaleK2s)
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:realKubectlExe -Path $script:userKubeconfig
        $savedOutputEncoding = [Console]::OutputEncoding
        try {
            # OEM code page 437 cannot represent the CJK characters of the AKS context name.
            [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(437)
            Add-K8sContext
        }
        finally {
            [Console]::OutputEncoding = $savedOutputEncoding
        }

        Assert-UpdatedUserKubeconfig -KubectlPath $script:realKubectlExe -OriginalParsed $originalParsed `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames | Out-Null
    }

    It 'repeated execution is byte-identical and renewal updates only K2s entries' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName)
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:realKubectlExe -Path $script:userKubeconfig

        Add-K8sContext
        $first = Get-FileBase64 $script:userKubeconfig
        Add-K8sContext
        Get-FileBase64 $script:userKubeconfig | Should -BeExactly $first

        Write-TestFile -Path $script:k2sSourcePath -Content (New-K2sSourceText -Seed 77)
        Add-K8sContext
        Assert-UpdatedUserKubeconfig -KubectlPath $script:realKubectlExe -OriginalParsed $originalParsed `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames | Out-Null
        Assert-NoTemporaryFiles
    }

    It 'keeps relative certificate paths resolvable from the .kube directory' {
        $clusters = @([ordered]@{ name = 'local-ca'; cluster = [ordered]@{ 'certificate-authority' = 'certs\ca.crt'; server = 'https://local:6443' } })
        $users = @([ordered]@{ name = 'local-user'; user = [ordered]@{ token = 'abc' } })
        $contexts = @([ordered]@{ name = 'local'; context = [ordered]@{ cluster = 'local-ca'; user = 'local-user' } })
        Initialize-ExistingUserKubeconfig -Content (New-KubeconfigText -Clusters $clusters -Users $users -Contexts $contexts -CurrentContext 'local')
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:realKubectlExe -Path $script:userKubeconfig

        Add-K8sContext

        Assert-UpdatedUserKubeconfig -KubectlPath $script:realKubectlExe -OriginalParsed $originalParsed -ForeignContexts @('local') -ForeignClusters @('local-ca') -ForeignUsers @('local-user') | Out-Null
        [System.IO.File]::ReadAllText($script:userKubeconfig) | Should -Match 'certificate-authority: certs\\ca\.crt'
    }

    It 'leaves the user kubeconfig unchanged when <Case>' -ForEach @(
        @{ Case = 'the K2s kubeconfig is malformed'; Setup = { Write-TestFile -Path $script:k2sSourcePath -Content "apiVersion: v1`nclusters: [unterminated`n" } }
        @{ Case = 'the K2s kubeconfig lacks the K2s context'; Setup = { Write-TestFile -Path $script:k2sSourcePath -Content (New-KubeconfigText -Clusters @(New-K2sCluster 1) -Users @(New-K2sUser 1)) } }
        @{ Case = 'the user kubeconfig is malformed'; Setup = { Write-TestFile -Path $script:userKubeconfig -Content "apiVersion: v1`ncontexts: [unterminated`n"; $script:originalUserBytes = Get-FileBase64 $script:userKubeconfig } }
        @{ Case = 'the user kubeconfig is read-only'; Setup = { (Get-Item $script:userKubeconfig).IsReadOnly = $true } }
    ) {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        & $Setup

        { Add-K8sContext } | Should -Throw

        Assert-UserKubeconfigUnchanged
    }
}
