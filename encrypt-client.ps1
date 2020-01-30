
$kv = Get-AzureRmKeyVault -ResourceGroupName "win10deploy-rg"


$clientInfo = @{}
$clientInfo.Id = ((Get-AzureKeyVaultSecret -VaultName $kv.VaultName -Name "ClientEncryptId")) | ConvertTo-SecureString -AsPlainText -Force
$clientInfo.Secret = ((Get-AzureKeyVaultSecret -VaultName $kv.VaultName -Name "ClientEncryptSecret")) | ConvertTo-SecureString -AsPlainText -Force

$client = New-Object –TypeName PSObject –Prop $clientInfo

Set-AzureRmVMDiskEncryptionExtension -ResourceGroupName win10deploy-rg `
                -VMName "win10skw-03" `
                -AadClientID $client.Id `
                -AadClientSecret $client.Secret `
                -DiskEncryptionKeyVaultUrl $kv.VaultUri `
                -DiskEncryptionKeyVaultId $kv.Id `
                -VolumeType All
