# Brava Edge Collector — Installation

`install.sh` detects the host Linux architecture (`amd64` or `arm64`) and downloads the matching self-extracting Brava Edge Collector installer from the [Brava Resources releases](https://github.com/Brava-Security/brava-resources/releases).

For full Linux, Windows, Docker, and Kubernetes installation instructions, see the [Edge Collector Installation Guide](https://docs.brava.security/edge-collector/installation/).

## Linux One-Line Install

```bash
curl -sSL https://github.com/Brava-Security/brava-resources/releases/latest/download/install.sh | sudo bash -s -- \
  --api-key "<YOUR_API_KEY>" \
  --router-host "<YOUR_ROUTER_HOST>" \
  --uri-path "<YOUR_URI_PATH>"
```

## Windows Install (PowerShell)

```powershell
Invoke-WebRequest -Uri https://github.com/Brava-Security/brava-resources/releases/latest/download/install-windows-amd64.zip -OutFile brava-windows.zip
Expand-Archive brava-windows.zip -DestinationPath brava-windows
cd brava-windows
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1 `
  -ApiKey "<YOUR_API_KEY>" `
  -RouterHost "<YOUR_ROUTER_HOST>" `
  -Channels "Application,System,Security,Microsoft-Windows-PowerShell/Operational"
```
