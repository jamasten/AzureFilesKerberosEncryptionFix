@description('A suffix to use for naming deployments uniquely. It defaults to the Bicep resolution of the "utcNow()" function.')
param deploymentNameSuffix string = utcNow()

@description('The name of the disk on the virtual machine.')
param diskName string

@allowed([
  'Premium_LRS'
  'StandardSSD_LRS'
  'Premium_ZRS'
])
@description('The SKU of the disk to use for the virtual machine.')
param diskSku string = 'Premium_LRS'

@secure()
@description('The password for the account to manage the Kerberos encryption on the file share.')
param domainAdminPassword string

@description('The user principal name for the account to manage the Kerberos encryption on the file share.')
param domainAdminUserPrincipalName string

@description('The FQDN of the Active Directory domain to join.')
param domainName string

@description('The deployment location for the Azure resources.')
param location string = resourceGroup().location

@description('The name of the user assigned managed identity.')
param managedIdentityName string

@description('The name of the network interface for the virtual machine.')
param networkInterfaceName string

@description('The organizational unit path for the virtual machine and storage account in the Active Directory domain.')
param organizationalUnitPath string = ''

@description('The name of the existing storage account containing the file share.')
param storageAccountName string

@description('The resource ID of the existing subnet for the network interface on the virtual machine.')
param subnetResourceId string

@description('The Key / value pairs of metadata for the Azure resource groups and resources.')
param tags object = {}

@description('This value is used for updating VM extensions. The default value should not be overridden.')
param timestamp string = utcNow('yyyyMMddhhmmss')

@description('The username for the administrator account on the virtual machine.')
param virtualMachineAdminUsername string

@secure()
@description('The password for the administrator account on the virtual machine.')
param virtualMachineAdminPassword string

@description('The name of the virtual machine')
param virtualMachineName string

@description('The size of the virtual machine.')
param virtualMachineSize string


resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' =  {
  name: managedIdentityName
  location: location
  tags: tags
}

module roleAssignment_storageAccountContributor 'modules/role-assignments/resource-group.bicep' = {
  name: 'assign-role-storage-${deploymentNameSuffix}'
  params: {
    principalId: userAssignedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: '17d1049b-9a84-46fb-8f53-869881c3d3ab'
  }
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2020-05-01' = {
  name: networkInterfaceName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetResourceId
          }
          primary: true
          privateIPAddressVersion: 'IPv4'
        }
      }
    ]
    enableAcceleratedNetworking: false
    enableIPForwarding: false
  }
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2021-11-01' = {
  name: virtualMachineName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: virtualMachineSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2019-datacenter-core-g2'
        version: 'latest'
      }
      osDisk: {
        deleteOption: 'Delete'
        osType: 'Windows'
        createOption: 'FromImage'
        caching: 'None'
        managedDisk: {
          storageAccountType: diskSku
        }
        name: diskName
      }
      dataDisks: []
    }
    osProfile: {
      adminPassword: virtualMachineAdminPassword
      adminUsername: virtualMachineAdminUsername
      computerName: virtualMachineName
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: false
      }
      secrets: []
      allowExtensionOperations: true
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    securityProfile: {
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
      securityType: 'TrustedLaunch'
      encryptionAtHost: true
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: false
      }
    }
    licenseType: 'Windows_Server'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentity.id}': {}
    }
  }
}

resource extension_GuestAttestation 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = {
  parent: virtualMachine
  name: 'GuestAttestation'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Security.WindowsAttestation'
    type: 'GuestAttestation'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    settings: {
      AttestationConfig: {
        MaaSettings: {
          maaEndpoint: ''
          maaTenantName: 'GuestAttestation'
        }
        AscSettings: {
          ascReportingEndpoint: ''
          ascReportingFrequency: ''
        }
        useCustomToken: 'false'
        disableAlerts: 'false'
      }
    }
  }
}

resource extension_JsonADDomainExtension 'Microsoft.Compute/virtualMachines/extensions@2019-07-01' = {
  parent: virtualMachine
  name: 'JsonADDomainExtension'
  location: location
  tags: tags
  properties: {
    forceUpdateTag: timestamp
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: {
      Name: domainName
      Options: '3'
      OUPath: organizationalUnitPath
      Restart: 'true'
      User: domainAdminUserPrincipalName
    }
    protectedSettings: {
      Password: domainAdminPassword
    }
  }
}

module roleAssignment_virtualMachineContributor 'modules/role-assignments/virtual-machine.bicep' = {
  name: 'assign-role-vm-${deploymentNameSuffix}'
  params: {
    principalId: userAssignedIdentity.properties.principalId
    roleDefinitionId: '9980e02c-c2be-4d73-94e8-173b1dc7cf3c' // Virtual Machine Contributor
    virtualMachineName: virtualMachine.name
  }
}

resource runCommand_kerberosEncryption 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: virtualMachine
  name: 'Set-KerberosEncryption'
  location: location
  tags: tags 
  properties: {
    asyncExecution: false
    parameters: [
      {
        name: 'Netbios'
        value: split(domainName, '.')[0]
      }
      {
        name: 'OrganizationalUnitPath'
        value: organizationalUnitPath
      }
      {
        name: 'ResourceManagerUri'
        value: environment().resourceManager
      }
      {
        name: 'StorageAccountName'
        value: storageAccountName
      }
      {
        name: 'StorageAccountResourceGroupName'
        value: resourceGroup().name
      }
      {
        name: 'StorageSuffix'
        value: environment().suffixes.storage
      }
      {
        name: 'SubscriptionId'
        value: subscription().subscriptionId
      }
      {
        name: 'UserAssignedIdentityClientId'
        value: userAssignedIdentity.properties.clientId
      }
    ]
    protectedParameters: [
      {
        name: 'DomainAdminPassword'
        value: domainAdminPassword
      }
      {
        name: 'DomainAdminUserPrincipalName'
        value: domainAdminUserPrincipalName
      }
    ]
    source: {
      script: loadTextContent('artifacts/Set-AzureFilesKerberosEncryption.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
}

resource runCommand_cleanUp 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: virtualMachine
  name: 'Remove-VirtualMachine'
  location: location
  tags: tags 
  properties: {
    asyncExecution: true
    parameters: [
      {
        name: 'ResourceGroupName'
        value: resourceGroup().name
      }
      {
        name: 'ResourceManagerUri'
        value: environment().resourceManager
      }
      {
        name: 'UserAssignedIdentityClientId'
        value: userAssignedIdentity.properties.clientId
      }
      {
        name: 'VirtualMachineResourceId'
        value: virtualMachine.id
      }
    ]
    source: {
      script: loadTextContent('artifacts/Remove-VirtualMachine.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    runCommand_kerberosEncryption
  ]
}
