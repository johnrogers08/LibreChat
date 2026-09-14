@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short, globally unique suffix used in resource names.')
@minLength(4)
@maxLength(12)
param resourceSuffix string

@description('Immutable ACR image tag to deploy. Supply an existing tag after the first image build.')
param imageTag string = 'bootstrap'

@description('Whether to create or update the Container App. Set false for the initial foundation bootstrap.')
param deployApp bool = true

@description('Whether to create app managed-identity role assignments. Set false for CI deployments after bootstrap.')
param assignAppRoles bool = true

@description('Whether to create GitHub deployment-identity role assignments. Set false for CI deployments after bootstrap.')
param assignDeploymentRoles bool = true

@description('GitHub repository allowed to obtain Azure deployment tokens, in owner/repository form.')
param githubRepository string

@description('Microsoft Entra tenant ID used for LibreChat user authentication.')
param entraTenantId string

@description('Microsoft Entra application (client) ID used for LibreChat user authentication.')
param entraClientId string

@secure()
@description('Client secret for the Microsoft Entra application registration.')
param entraClientSecret string

@secure()
@description('Session secret used for OpenID Connect authentication state.')
param openIdSessionSecret string

@secure()
@description('Password for the Cosmos DB for MongoDB vCore administrator login.')
param mongoAdminPassword string

@secure()
@description('LibreChat session-encryption key stored as a Key Vault secret.')
param credsKey string

@secure()
@description('LibreChat session-encryption IV stored as a Key Vault secret.')
param credsIv string

@secure()
@description('LibreChat JWT signing secret stored as a Key Vault secret.')
param jwtSecret string

@minValue(1)
param minReplicas int = 1

@minValue(1)
param maxReplicas int = 3

var suffix = toLower(resourceSuffix)
var prefix = 'lc${suffix}'
var registryName = take('${prefix}acr', 50)
var appName = take('${prefix}-app', 32)
var environmentName = take('${prefix}-cae', 60)
var appIdentityName = take('${prefix}-app-id', 128)
var deploymentIdentityName = take('${prefix}-github-id', 128)
var vaultName = take('${prefix}-kv', 24)
var storageName = take('${prefix}store', 24)
var workspaceName = take('${prefix}-logs', 63)
var mongoClusterName = take('${prefix}-mongo', 40)
var mongoAdministratorLogin = 'librechat_app'
var appDomain = 'https://${appName}.${environment.properties.defaultDomain}'

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: workspace.properties.customerId
        sharedKey: workspace.listKeys().primarySharedKey
      }
    }
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: registryName
  location: location
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: appIdentityName
  location: location
}

resource deploymentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: deploymentIdentityName
  location: location
}

resource githubMainFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: deploymentIdentity
  name: 'github-main'
  properties: {
    audiences: ['api://AzureADTokenExchange']
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:${githubRepository}:ref:refs/heads/main'
  }
}

resource githubProductionFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: deploymentIdentity
  name: 'github-production'
  properties: {
    audiences: ['api://AzureADTokenExchange']
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:${githubRepository}:environment:production'
  }
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: vaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A' name: 'standard' }
    enableRbacAuthorization: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 90
  }
}

resource mongoCluster 'Microsoft.DocumentDB/mongoClusters@2024-07-01' = {
  name: mongoClusterName
  location: location
  properties: {
    administratorLogin: mongoAdministratorLogin
    administratorLoginPassword: mongoAdminPassword
    serverVersion: '8.0'
    nodeGroupSpecs: [
      {
        kind: 'Shard'
        sku: 'M30'
        diskSizeGB: 32
        nodeCount: 3
      }
    ]
  }
}

resource mongoUriSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'mongo-uri'
  properties: { value: mongoCluster.properties.connectionString }
}

resource entraClientSecretSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'entra-client-secret'
  properties: { value: entraClientSecret }
}

resource openIdSessionSecretValue 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'openid-session-secret'
  properties: { value: openIdSessionSecret }
}

resource credsKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'creds-key'
  properties: { value: credsKey }
}

resource credsIvSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'creds-iv'
  properties: { value: credsIv }
}

resource jwtSecretSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'jwt-secret'
  properties: { value: jwtSecret }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource files 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: storage
  name: 'default/files'
  properties: { publicAccess: 'None' }
}

resource appAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignAppRoles) {
  name: guid(registry.id, appIdentity.properties.principalId, 'AcrPull')
  scope: registry
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}

resource appBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignAppRoles) {
  name: guid(storage.id, appIdentity.properties.principalId, 'StorageBlobDataContributor')
  scope: storage
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}

resource appSecretReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignAppRoles) {
  name: guid(vault.id, appIdentity.properties.principalId, 'KeyVaultSecretsUser')
  scope: vault
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
}

resource githubContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignDeploymentRoles) {
  name: guid(resourceGroup().id, deploymentIdentity.properties.principalId, 'Contributor')
  properties: {
    principalId: deploymentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
  }
}

resource githubAcrPush 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignDeploymentRoles) {
  name: guid(registry.id, deploymentIdentity.properties.principalId, 'AcrPush')
  scope: registry
  properties: {
    principalId: deploymentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8311e382-0749-4cb8-b61a-304f252e45ec')
  }
}

resource app 'Microsoft.App/containerApps@2024-03-01' = if (deployApp) {
  name: appName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${appIdentity.id}': {} }
  }
  properties: {
    managedEnvironmentId: environment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true targetPort: 3080 transport: 'auto' allowInsecure: false }
      registries: [{ server: registry.properties.loginServer identity: appIdentity.id }]
      secrets: [
        { name: 'librechat-config' value: loadTextContent('librechat.azure.yaml') }
        { name: 'entra-client-secret' keyVaultUrl: entraClientSecretSecret.properties.secretUriWithVersion identity: appIdentity.id }
        { name: 'mongo-uri' keyVaultUrl: mongoUriSecret.properties.secretUriWithVersion identity: appIdentity.id }
        { name: 'openid-session-secret' keyVaultUrl: openIdSessionSecretValue.properties.secretUriWithVersion identity: appIdentity.id }
        { name: 'creds-key' keyVaultUrl: credsKeySecret.properties.secretUriWithVersion identity: appIdentity.id }
        { name: 'creds-iv' keyVaultUrl: credsIvSecret.properties.secretUriWithVersion identity: appIdentity.id }
        { name: 'jwt-secret' keyVaultUrl: jwtSecretSecret.properties.secretUriWithVersion identity: appIdentity.id }
      ]
    }
    template: {
      containers: [{
        name: 'librechat'
        image: '${registry.properties.loginServer}/librechat:${imageTag}'
        env: [
          { name: 'NODE_ENV' value: 'production' }
          { name: 'HOST' value: '0.0.0.0' }
          { name: 'TRUST_PROXY' value: '1' }
          { name: 'DOMAIN_CLIENT' value: appDomain }
          { name: 'DOMAIN_SERVER' value: appDomain }
          { name: 'CONFIG_PATH' value: '/app/config/librechat.yaml' }
          { name: 'OPENID_CLIENT_ID' value: entraClientId }
          { name: 'OPENID_ISSUER' value: 'https://login.microsoftonline.com/${entraTenantId}/v2.0' }
          { name: 'OPENID_SCOPE' value: 'openid profile email' }
          { name: 'OPENID_CALLBACK_URL' value: '/oauth/openid/callback' }
          { name: 'OPENID_EMAIL_CLAIM' value: 'preferred_username' }
          { name: 'OPENID_BUTTON_LABEL' value: 'Sign in with Microsoft' }
          { name: 'OPENID_CLIENT_SECRET' secretRef: 'entra-client-secret' }
          { name: 'OPENID_SESSION_SECRET' secretRef: 'openid-session-secret' }
          { name: 'AZURE_STORAGE_ACCOUNT_NAME' value: storage.name }
          { name: 'AZURE_CONTAINER_NAME' value: 'files' }
          { name: 'AZURE_STORAGE_PUBLIC_ACCESS' value: 'false' }
          { name: 'MONGO_URI' secretRef: 'mongo-uri' }
          { name: 'CREDS_KEY' secretRef: 'creds-key' }
          { name: 'CREDS_IV' secretRef: 'creds-iv' }
          { name: 'JWT_SECRET' secretRef: 'jwt-secret' }
        ]
        volumeMounts: [
          { volumeName: 'config' mountPath: '/app/config' }
        ]
        resources: { cpu: 1.0 memory: '2Gi' }
        probes: [
          { type: 'Startup' httpGet: { path: '/health' port: 3080 } initialDelaySeconds: 10 periodSeconds: 10 failureThreshold: 30 }
          { type: 'Readiness' httpGet: { path: '/health' port: 3080 } periodSeconds: 10 failureThreshold: 3 }
          { type: 'Liveness' httpGet: { path: '/health' port: 3080 } periodSeconds: 30 failureThreshold: 3 }
        ]
      }]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [{ name: 'http-concurrency' http: { metadata: { concurrentRequests: '50' } } }]
      }
      volumes: [
        {
          name: 'config'
          storageType: 'Secret'
          secrets: [
            { secretRef: 'librechat-config' path: 'librechat.yaml' }
          ]
        }
      ]
    }
  }
}

output containerAppUrl string = deployApp ? 'https://${app.properties.configuration.ingress.fqdn}' : ''
output containerAppName string = appName
output containerAppsEnvironmentName string = environment.name
output containerRegistryName string = registry.name
output containerRegistryLoginServer string = registry.properties.loginServer
output logAnalyticsWorkspaceName string = workspace.name
output keyVaultName string = vault.name
output storageAccountName string = storage.name
output storageContainerName string = files.name
output appIdentityName string = appIdentity.name
output appIdentityClientId string = appIdentity.properties.clientId
output deploymentIdentityName string = deploymentIdentity.name
output deploymentIdentityClientId string = deploymentIdentity.properties.clientId
output mongoClusterName string = mongoCluster.name
output mongoAdministratorLogin string = mongoAdministratorLogin
output mongoDatabaseName string = 'LibreChat'
output entraRedirectUri string = '${appDomain}/oauth/openid/callback'