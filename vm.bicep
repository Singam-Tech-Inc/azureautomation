param location string = resourceGroup().location
param vmName string = 'myVM'
param adminUsername string = 'azureuser'
@secure()
param adminPassword string // Use a secure method to handle passwords
param vmSize string = 'Standard_B2s'
param vnetName string = 'myVnet'
param subnetName string = 'mySubnet'
param staticPrivateIP string = '10.0.0.4'
param proximityPlacementGroupName string = 'myProximityPlacementGroup'
param automationAccountName string = 'myExistingAutomationAccount'
param actionGroupId string = '/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/microsoft.insights/actionGroups/<action-group-name>'
@allowed([
  'true'
  'false'
])
param enableBackup bool = 'false'
param recoveryServicesVaultName string = 'myRecoveryServicesVault'
param backupPolicyName string = 'myBackupPolicy'

resource vnet 'Microsoft.Network/virtualNetworks@2020-06-01' existing = {
  name: vnetName
  scope: resourceGroup()
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2020-06-01' existing = {
  parent: vnet
  name: subnetName
}

resource nic 'Microsoft.Network/networkInterfaces@2020-06-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnet.id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: staticPrivateIP
        }
      }
    ]
  }
}

resource proximityPlacementGroup 'Microsoft.Compute/proximityPlacementGroups@2020-06-01' existing = {
  name: proximityPlacementGroupName
}

resource vm 'Microsoft.Compute/virtualMachines@2020-06-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'UbuntuServer'
        sku: '22.04-LTS'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    proximityPlacementGroup: {
      id: proximityPlacementGroup.id
    }
  }
}

resource customScriptExtension 'Microsoft.Compute/virtualMachines/extensions@2020-06-01' = {
  name: 'customScriptExtension'
  parent: vm
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: []
      commandToExecute: '''
        sudo apt-get update &&
        sudo apt-get install -y python3.12 build-essential golang rustc g++ &&
        sudo apt-get install -y python3-pip &&
        python3.12 -m pip install --user pipx &&
        python3.12 -m pipx ensurepath
      '''
    }
  }
}

resource cpuAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${vmName}-cpu-alert'
  location: location
  properties: {
    description: 'CPU usage alert'
    severity: 3
    enabled: true
    scopes: [
      vm.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          metricName: 'Percentage CPU'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

resource memoryAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${vmName}-memory-alert'
  location: location
  properties: {
    description: 'Memory usage alert'
    severity: 3
    enabled: true
    scopes: [
      vm.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          metricName: 'Available Memory Bytes'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          operator: 'LessThan'
          threshold: 500000000
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

resource startVMRunbook 'Microsoft.Automation/automationAccounts/runbooks@2020-01-13-preview' = {
  name: '${automationAccountName}/StartVMRunbook-${vmName}'
  location: location
  properties: {
    logVerbose: true
    logProgress: true
    description: 'Runbook to start the VM'
    runbookType: 'PowerShell'
    draft: {
      inEdit: false
    }
  }
  content: '''
    param (
      [string]$vmName,
      [string]$resourceGroupName
    )
    Start-AzVM -ResourceGroupName $resourceGroupName -Name $vmName
  '''
}

resource stopVMRunbook 'Microsoft.Automation/automationAccounts/runbooks@2020-01-13-preview' = {
  name: '${automationAccountName}/StopVMRunbook-${vmName}'
  location: location
  properties: {
    logVerbose: true
    logProgress: true
    description: 'Runbook to stop the VM'
    runbookType: 'PowerShell'
    draft: {
      inEdit: false
    }
  }
  content: '''
    param (
      [string]$vmName,
      [string]$resourceGroupName
    )
    Stop-AzVM -ResourceGroupName $resourceGroupName -Name $vmName -Force
  '''
}

resource startVMSchedule 'Microsoft.Automation/automationAccounts/schedules@2020-01-13-preview' = {
  name: 'StartVMSchedule-${vmName}'
  properties: {
    description: 'Schedule to start the VM at 7 AM'
    startTime: '2023-01-01T07:00:00Z'
    expiryTime: '2025-01-01T07:00:00Z'
    interval: '1'
    frequency: 'Day'
    timeZone: 'UTC'
  }
}

resource stopVMSchedule 'Microsoft.Automation/automationAccounts/schedules@2020-01-13-preview' = {
  name: 'StopVMSchedule-${vmName}'
  properties: {
    description: 'Schedule to stop the VM at 7 PM'
    startTime: '2023-01-01T19:00:00Z'
    expiryTime: '2025-01-01T19:00:00Z'
    interval: '1'
    frequency: 'Day'
    timeZone: 'UTC'
  }
}

resource startVMJob 'Microsoft.Automation/automationAccounts/jobSchedules@2020-01-13-preview' = {
  name: 'StartVMJob-${vmName}'
  properties: {
    runbook: {
      name: startVMRunbook.name
    }
    schedule: {
      name: startVMSchedule.name
    }
    parameters: {
      vmName: vmName
      resourceGroupName: resourceGroup().name
    }
  }
}

resource stopVMJob 'Microsoft.Automation/automationAccounts/jobSchedules@2020-01-13-preview' = {
  name: 'StopVMJob-${vmName}'
  properties: {
    runbook: {
      name: stopVMRunbook.name
    }
    schedule: {
      name: stopVMSchedule.name
    }
    parameters: {
      vmName: vmName
      resourceGroupName: resourceGroup().name
    }
  }
}

resource backupPolicy 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2021-06-01' = if (enableBackup) {
  name: '${recoveryServicesVaultName}/Azure/protectionContainers/iaasvmcontainer;iaasvmcontainerv2;${resourceGroup().name};${vmName}/protectedItems/vm;${vmName}'
  location: location
  properties: {
    policyId: subscriptionResourceId('Microsoft.RecoveryServices/vaults/backupPolicies', recoveryServicesVaultName, backupPolicyName)
    protectedItemType: 'Microsoft.Compute/virtualMachines'
    sourceResourceId: vm.id
  }
}
