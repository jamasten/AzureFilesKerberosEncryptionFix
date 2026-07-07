param 
(
    [String]$DomainAdminPassword,
    [String]$DomainAdminUserPrincipalName,
    [String]$OrganizationalUnitPath,
    [String]$ResourceManagerUri,
    [String]$StorageAccountName,
    [String]$StorageAccountResourceGroupName,
    [String]$StorageSuffix,
    [String]$SubscriptionId,
    [String]$UserAssignedIdentityClientId
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'

# Install Active Directory PowerShell module
$RsatInstalled = (Get-WindowsFeature -Name 'RSAT-AD-PowerShell').Installed
if(!$RsatInstalled)
{
    Install-WindowsFeature -Name 'RSAT-AD-PowerShell' | Out-Null
}

# Create Domain credential
$DomainUsername = $DomainAdminUserPrincipalName
$DomainPassword = ConvertTo-SecureString -String $DomainAdminPassword -AsPlainText -Force
[pscredential]$DomainCredential = New-Object System.Management.Automation.PSCredential ($DomainUsername, $DomainPassword)

# Get Domain information
$Domain = Get-ADDomain -Credential $DomainCredential -Current 'LocalComputer'

# Set suffix for Azure Files
$FilesSuffix = '.file.' + $StorageSuffix

# Fix the resource manager URI since only AzureCloud contains a trailing slash
$ResourceManagerUriFixed = if ($ResourceManagerUri[-1] -eq '/') { $ResourceManagerUri.Substring(0, $ResourceManagerUri.Length - 1) } else { $ResourceManagerUri }

# Get an access token for Azure resources
$AzureManagementAccessToken = (Invoke-RestMethod `
    -Headers @{Metadata = "true" } `
    -Uri $('http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' + $ResourceManagerUriFixed + '&client_id=' + $UserAssignedIdentityClientId)).access_token

# Set header for Azure Management API
$AzureManagementHeader = @{
    'Content-Type'  = 'application/json'
    'Authorization' = 'Bearer ' + $AzureManagementAccessToken
}

# Get / create kerberos key for Azure Storage Account
$KerberosKey = ((Invoke-RestMethod `
    -Headers $AzureManagementHeader `
    -Method 'POST' `
    -Uri $($ResourceManagerUriFixed + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $StorageAccountResourceGroupName + '/providers/Microsoft.Storage/storageAccounts/' + $StorageAccountName + '/listKeys?api-version=2023-05-01&$expand=kerb')).keys | Where-Object { $_.Keyname -contains 'kerb1' }).Value

if (!$KerberosKey) 
{
    Invoke-RestMethod `
        -Body (@{keyName = 'kerb1' } | ConvertTo-Json) `
        -Headers $AzureManagementHeader `
        -Method 'POST' `
        -Uri $($ResourceManagerUriFixed + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $StorageAccountResourceGroupName + '/providers/Microsoft.Storage/storageAccounts/' + $StorageAccountName + '/regenerateKey?api-version=2023-05-01')
    
    $Key = ((Invoke-RestMethod `
        -Headers $AzureManagementHeader `
        -Method 'POST' `
        -Uri $($ResourceManagerUriFixed + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $StorageAccountResourceGroupName + '/providers/Microsoft.Storage/storageAccounts/' + $StorageAccountName + '/listKeys?api-version=2023-05-01&$expand=kerb')).keys | Where-Object { $_.Keyname -contains 'kerb1' }).Value
} 
else 
{
    $Key = $KerberosKey
}

# Creates a password for the Azure Storage Account in AD using the Kerberos key
$ComputerPassword = ConvertTo-SecureString -String $Key.Replace("'","") -AsPlainText -Force

# Create the SPN value for the Azure Storage Account; attribute for computer object in AD 
$SPN = 'cifs/' + $StorageAccountName + $FilesSuffix

# Create the Description value for the Azure Storage Account; attribute for computer object in AD 
$Description = "Computer account object for Azure storage account $($StorageAccountName)."

# Create the AD computer object for the Azure Storage Account
$OldComputerObject = Get-ADComputer -Credential $DomainCredential -Filter {Name -eq $StorageAccountName}
if ($OldComputerObject)
{
    $OldComputerObject | Remove-ADObject -Credential $DomainCredential -Recursive -Confirm:$false
}

$SamAccountName = if($StorageAccountName.Length -gt 19) { $StorageAccountName.Substring(0, 19) } else { $StorageAccountName }
if ($OrganizationalUnitPath) {
    $NewComputerObject = New-ADComputer -Credential $DomainCredential -Name $StorageAccountName -SamAccountName $SamAccountName -Path $OrganizationalUnitPath -ServicePrincipalNames $SPN -AccountPassword $ComputerPassword -Description $Description -PassThru
} else {
    $NewComputerObject = New-ADComputer -Credential $DomainCredential -Name $StorageAccountName -SamAccountName $SamAccountName -ServicePrincipalNames $SPN -AccountPassword $ComputerPassword -Description $Description -PassThru
}

$Body = (@{
    properties = @{
        azureFilesIdentityBasedAuthentication = @{
            activeDirectoryProperties = @{
                accountType = 'Computer'
                azureStorageSid = $NewComputerObject.SID.Value
                domainGuid = $Domain.ObjectGUID.Guid
                domainName = $Domain.DNSRoot
                domainSid = $Domain.DomainSID.Value
                forestName = $Domain.Forest
                netBiosDomainName = $Domain.NetBIOSName
                samAccountName = $StorageAccountName
            }
            directoryServiceOptions = 'AD'
        }
    }
} | ConvertTo-Json -Depth 6 -Compress)

Invoke-RestMethod `
    -Body $Body `
    -Headers $AzureManagementHeader `
    -Method 'PATCH' `
    -Uri $($ResourceManagerUriFixed + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $StorageAccountResourceGroupName + '/providers/Microsoft.Storage/storageAccounts/' + $StorageAccountName + '?api-version=2023-05-01')

# Set the Kerberos encryption on the computer object
Set-ADComputer -Credential $DomainCredential -Identity $StorageAccountName -KerberosEncryptionType 'AES256' | Out-Null

# Reset the Kerberos key on the Storage Account
Invoke-RestMethod `
    -Body (@{keyName = 'kerb1' } | ConvertTo-Json) `
    -Headers $AzureManagementHeader `
    -Method 'POST' `
    -Uri $($ResourceManagerUriFixed + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $StorageAccountResourceGroupName + '/providers/Microsoft.Storage/storageAccounts/' + $StorageAccountName + '/regenerateKey?api-version=2023-05-01')

$Key = ((Invoke-RestMethod `
    -Headers $AzureManagementHeader `
    -Method 'POST' `
    -Uri $($ResourceManagerUriFixed + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $StorageAccountResourceGroupName + '/providers/Microsoft.Storage/storageAccounts/' + $StorageAccountName + '/listKeys?api-version=2023-05-01&$expand=kerb')).keys | Where-Object { $_.Keyname -contains 'kerb1' }).Value

# Update the password on the computer object with the new Kerberos key on the Storage Account
$NewPassword = ConvertTo-SecureString -String $Key -AsPlainText -Force
Set-ADAccountPassword -Credential $DomainCredential -Identity $($StorageAccountName + '$') -Reset -NewPassword $NewPassword | Out-Null