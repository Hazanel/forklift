# Hyper-V Host Prerequisites

Before using the Hyper-V provider, the following must be configured on the Hyper-V host.

## 1. Enable WinRM (Windows Remote Management)

```powershell
# Run as Administrator on Hyper-V host
Enable-PSRemoting -Force
winrm quickconfig

# Allow Basic authentication (required for non-domain environments)
winrm set winrm/config/service/auth '@{Basic="true"}'

# Verify WinRM is running
Get-Service WinRM
```

> **Note:** Forklift uses WinRM HTTPS (port 5986) for security. HTTP (port 5985) is not supported in production. See section 2 to configure HTTPS.

## 2. Configure WinRM HTTPS (TLS)

WinRM HTTPS must be configured with a certificate that includes the host IP in its Subject Alternative Names (SAN).

```powershell
# Step 1: Create self-signed certificate with IP SAN
# Replace 192.168.1.218 with your host IP
$cert = New-SelfSignedCertificate `
    -Subject "CN=192.168.1.218" `
    -CertStoreLocation Cert:\LocalMachine\My `
    -TextExtension @("2.5.29.17={text}IPAddress=192.168.1.218") `
    -KeyUsage DigitalSignature,KeyEncipherment `
    -KeySpec KeyExchange

$cert.Thumbprint

# Step 2: Create WinRM HTTPS listener
winrm create winrm/config/Listener?Address=*+Transport=HTTPS `
    "@{Hostname=`"192.168.1.218`"; CertificateThumbprint=`"$($cert.Thumbprint)`"}"

# Step 3: Open firewall for WinRM HTTPS
netsh advfirewall firewall add rule name="WinRM HTTPS" dir=in action=allow protocol=TCP localport=5986

# Verify
winrm enumerate winrm/config/Listener
```

**Important:**
- The certificate **must** include the IP address in the SAN, not just the CN.
- WinRM HTTPS uses port **5986** (not 443).
- For trusted certificates, use a CA trusted by the Forklift controller.

To export the certificate for the Forklift provider secret (`cacert` field):

```powershell
$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {$_.Subject -eq "CN=192.168.1.218"}
$bytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
[System.Convert]::ToBase64String($bytes)
```

## 3. Configure SMB Share for VHDX Access

```powershell
New-SmbShare -Name "HyperVDisks" -Path "C:\Hyper-V\Virtual_Hard_Disks" -FullAccess "Administrator" (Better to have same credentials as hyperV)
Get-SmbShare -Name "HyperVDisks"
```

## 4. Enable Integration Services on VMs

Integration Services must be installed on guest VMs for KVP (Key-Value Pair) data exchange.

**Windows guests** (built-in on Windows 8 / Server 2012+):

```powershell
Get-VMIntegrationService -VMName "vm-name"
```

**Linux guests:**

```bash
# RHEL/CentOS/Fedora
sudo dnf install hyperv-daemons

# Ubuntu/Debian
sudo apt install linux-cloud-tools-common linux-tools-virtual

# Verify
sudo systemctl status hv_kvp_daemon
```

## 5. Enable Data Exchange (KVP) on VMs

Data Exchange must be enabled for static IP detection:

```powershell
Enable-VMIntegrationService -VMName "vm-name" -Name "Key-Value Pair Exchange"

# Verify
Get-VMIntegrationService -VMName "vm-name" |
    Where-Object { $_.Name -eq "Key-Value Pair Exchange" }
```

Alternatively, in Hyper-V Manager: right-click VM → Settings → Management → Integration Services → check **Data Exchange**.

## 6. Firewall Configuration

```powershell
# WinRM HTTPS (required)
New-NetFirewallRule -Name "WinRM-HTTPS" -DisplayName "WinRM HTTPS" -Protocol TCP -LocalPort 5986 -Action Allow

# WinRM HTTP (testing only)
New-NetFirewallRule -Name "WinRM-HTTP" -DisplayName "WinRM HTTP" -Protocol TCP -LocalPort 5985 -Action Allow

# SMB (required for disk transfer)
New-NetFirewallRule -Name "SMB" -DisplayName "SMB" -Protocol TCP -LocalPort 445 -Action Allow
```

## 7. Verify Prerequisites

```powershell
# Test WinRM
Test-WSMan -ComputerName localhost

# Check Integration Services on all VMs
Get-VM | Select-Object Name, IntegrationServicesState

# Check Data Exchange status per VM
Get-VM | ForEach-Object {
    $kvp = Get-VMIntegrationService -VMName $_.Name |
        Where-Object { $_.Name -eq "Key-Value Pair Exchange" }
    [PSCustomObject]@{
        VMName              = $_.Name
        DataExchangeEnabled = $kvp.Enabled
        DataExchangeRunning = $kvp.OperationalStatus -contains "Ok"
    }
}
```
