function Get-AzureNeedLogin {

    $needLogin = $true
    Try {
        if ($content = Get-AzureRmContext) {
            $needLogin = ([string]::IsNullOrEmpty($content.Account))
        }
    }
    Catch {
        if ($_ -like "*Login-AzureRmAccount to login*")  {
            $needLogin = $true
        } 
        else {
            throw
        }
    }
    return $needLogin
}

#log in if required
If(Get-AzureNeedLogin){
    Login-AzureRmAccount
}

$vmSet = @()

#Collect environment settings and the list of clients to deploy from clients.json file...
if(!($deployCfg = (get-content -path ".\clients.json" -ErrorAction Ignore) | ConvertFrom-Json )) {
    throw "No configuration file in current directory!"
}

$thisDeploymentImage = $deployCfg.DeploymentImage
$thisRg = $deployCfg.ResourceGroup
$thisLocation = $deployCfg.Location
$thisKeyVault = $deployCfg.KeyVaultName

#change the resource group and vault name to fit the environment
$localVault = Get-AzureRmKeyVault -ResourceGroupName $thisRg -VaultName $thisKeyVault

#the following generates a default local admin account, which is needed to deploy the client OS...
$thisAdminAccount = $deployCfg.AdminAccountName
$thisAdminPassword = ((Get-AzureKeyVaultSecret -VaultName $localVault -Name $thisAdminAccount).SecretValueText) | ConvertTo-SecureString -AsPlainText -Force
$thisAdminCredential = New-Object System.Management.Automation.PSCredential ($thisAdminAccount, $thisAdminPassword)

Write-Host "Please wait while the following VMs are created:"
foreach($suffix in $deployCfg.machineSuffixes){

    $thisClient = "$($deployCfg.DeploymentName)-$suffix"
    $saveFile = "$thisClient.odj"
    $savePath = "C:\deployment\odjfiles"
    $saveFullPath = "$savePath\$saveFile"

    #Create a new identity for the client in Azure AD to use for unique account key
    $clientIdentity = New-AzureADApplication -DisplayName $thisClient -IdentifierUris "https://$thisClient"
    $clientSecret = New-AzureADApplicationPasswordCredential -ObjectId $clientIdentity.ObjectId 

    #Create a secret keyed on the client identity value, then allow it access to the secrets store
    Set-AzureKeyVaultSecret -VaultName $localVault.VaultName -Name $clientIdentity -SecretValue $clientSecret.Value
    Set-AzureRmKeyVaultAccessPolicy -VaultName $localVault -ApplicationId $clientIdentity.Id -PermissionsToSecrets get,set

    #Check to see if a odj blob exists, if not create it.
    if(!(get-item $saveFullPath -ErrorAction Ignore)) {
        write-host "Creating the domain join provisioning file..."
        djoin /PROVISION /DOMAIN contosopower.com /MACHINE $thisClient /SAVEFILE $saveFullPath
    }
    $odjBlob = Get-Content -Path $saveFullPath -Raw | ConvertTo-SecureString -AsPlainText -Force
    Set-AzureKeyVaultSecret -VaultName $localVault.VaultName -Name "$($thisClient)-odj" -ContentType "ODJBlob" -SecretValue $odjBlob

    #Create the VM's asynchronously and wait until they're all done.
    write-host "    -- $thisClient"
    $vmSet += New-AzureRmVm `
        -ResourceGroupName $deployCfg.ResourceGroup `
        -Name $thisClient `
        -Credential $thisAdminCredential `
        -Location $deployCfg.Location `
        -Size $deployCfg.VMSize `
        -VirtualNetworkName $deployCfg.VirtualNetwork `
        -SubnetName $deployCfg.Subnet `
        -SecurityGroupName $deployCfg.NetworkSecurityGroup `
        -PublicIpAddressName "$thisClient-pip" `
        -UserAssignedIdentity $clientIdentity.Id `
        -Image $thisDeploymentImage `
        -AsJob `
        -WhatIf
}

#wait for all provisioning tasks to complete.
Get-Job | Wait-Job

#Assume success and notify the user when the wait is over.
Write-Host "VMs created successfully."

Write-Host "Initiating the encryption of all VM disks..."
foreach ($vm in $vmset){
    $clientInfo = @{}
    $clientInfo.Id = ((Get-AzureKeyVaultSecret -VaultName $kv.VaultName -Name "ClientEncryptId")) | ConvertTo-SecureString -AsPlainText -Force
    $clientInfo.Secret = ((Get-AzureKeyVaultSecret -VaultName $kv.VaultName -Name "ClientEncryptSecret")) | ConvertTo-SecureString -AsPlainText -Force

    $client = New-Object –TypeName PSObject –Prop $clientInfo

    Set-AzureRmVMDiskEncryptionExtension `
                -ResourceGroupName $thisRg `
                -VMName $vm.Name `
                -AadClientID $client.Id `
                -AadClientSecret $client.Secret `
                -DiskEncryptionKeyVaultUrl $kv.VaultUri `
                -DiskEncryptionKeyVaultId $kv.Id `
                -VolumeType All
}

foreach($vm in $vmSet){

    $result = Invoke-AzureRmVMRunCommand `
        -ResourceGroupName $thisRg `
        -VMName $thisClient `
        -CommandId 'RunPowerShellScript' `
        -ScriptPath "c:\Deployment\join-addomain-kv.ps1" `
        -AsJob
}