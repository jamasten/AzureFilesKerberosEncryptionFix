param principalId string
param roleDefinitionId string
param virtualMachineName string

resource virtualMachine 'Microsoft.Compute/virtualMachines@2021-11-01' existing = {
  name: virtualMachineName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(principalId, roleDefinitionId, virtualMachine.id)
  scope: virtualMachine
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
  }
}
