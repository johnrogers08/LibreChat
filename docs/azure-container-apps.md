# Azure Container Apps Deployment

This deployment runs LibreChat as one stateless Azure Container App. MongoDB Atlas on Azure provides the database and Azure Blob Storage holds uploaded files. The Compose-only MongoDB, Meilisearch, pgvector, RAG, and admin-panel services are intentionally not deployed.

## Bootstrap

Create a resource group, then run the first deployment from a trusted machine using a principal that can create role assignments. Do not commit actual parameter values.

```bash
az group create --name <resource-group> --location <region>
az deployment group create --resource-group <resource-group> --template-file infra/main.bicep --parameters resourceSuffix=<unique-suffix> githubRepository=<owner/repository> deployApp=false mongoUri='<Atlas URI>' credsKey="$(openssl rand -hex 32)" credsIv="$(openssl rand -hex 16)" jwtSecret="$(openssl rand -hex 32)"
```

This foundation-only bootstrap creates the registry, identities, Key Vault, and storage without creating an app revision that references a nonexistent image. Configure Atlas network access for the Container Apps environment and a least-privilege database user before the first image deployment.

## GitHub Actions

Protect a GitHub `production` environment. Add repository variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_RESOURCE_GROUP`, `AZURE_LOCATION`, `AZURE_RESOURCE_SUFFIX`, and `AZURE_CONTAINER_REGISTRY_NAME`. Use the Bicep outputs for the client ID and registry name.

Add `MONGO_URI`, `CREDS_KEY`, `CREDS_IV`, and `JWT_SECRET` as `production` environment secrets. The workflow writes these as Key Vault secrets; the app receives them by Key Vault reference. OIDC federated credentials cover both the `main` build and the protected `production` deploy job, so do not configure `AZURE_CREDENTIALS`.

Pushing to `main` builds an immutable full-SHA image in ACR, then deploys it after environment approval. To roll back, run **Azure Container Apps Deploy** manually with a previously built full commit SHA.

## File Storage

The Container App uses its managed identity for Azure Blob access. Do not set `AZURE_STORAGE_CONNECTION_STRING`.

```yaml
version: 1.3.16
fileStrategies:
  avatar: azure_blob
  image: azure_blob
  document: azure_blob
  skills: azure_blob
```

The deployed `files` container is private. The app identity has Blob Data Contributor, and LibreChat authorizes downloads through application routes.