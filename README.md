# Azure Files Kerberos Encryption Fix

The purpose of this solution is to update Azure Files to use AES256 Kerberos encryption, instead of RC4.

## Prerequisites

- RBAC: Owner role
- Maintenance Window: to prevent data loss, users should not access the file share(s) on the storage account.

## Deployment Steps

- Open the Azure Portal
- Search for and open the "Deploy a custom template" option in Azure.
- Click on the "Build your own template in the editor" link.
- Copy and paste the code in the solution.json file into the code editor.
- Click "Save".
- Fill out the form and deploy the template.

## Validation

1. Connect the SMB file share to Windows host.
1. Open the Command Prompt.
1. Run "klist".
1. Find the file share associated with your Azure storage account.
1. Confirm the Kerberos encryption used with the file share.
