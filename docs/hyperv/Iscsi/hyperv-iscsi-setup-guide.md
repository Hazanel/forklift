# Hyper-V Provider -- iSCSI Setup Guide

This guide walks through everything needed to set up and test the Hyper-V provider
end-to-end using CLI only. It is intended for engineers starting from scratch.

Hyper-V migrations use **iSCSI Target Server** to transfer disk data. MTV
orchestrates the entire iSCSI lifecycle (create differencing disk, expose as
LUN, copy, clean up) automatically via WinRM — the admin only needs to install
the Windows feature and open the firewall port.

**Prerequisites on your workstation:** `oc`, `jq`.

---

## Table of Contents

1. [Hyper-V Host Setup](#1-hyper-v-host-setup)
2. [Verify Connectivity from Linux](#2-verify-connectivity-from-linux)
3. [OpenShift Cluster Prerequisites](#3-openshift-cluster-prerequisites)
4. [Create the Hyper-V Provider (YAML)](#4-create-the-hyper-v-provider)
5. [Discover Inventory](#5-discover-inventory)
6. [Create Network and Storage Maps](#6-create-network-and-storage-maps)
7. [Create a Migration Plan](#7-create-a-migration-plan)
8. [Start the Migration](#8-start-the-migration)
9. [Monitoring and Verification](#9-monitoring-and-verification)

---

## 1. Hyper-V Host Setup

All commands below run **on the Hyper-V host** as Administrator.
Replace `192.168.1.218` with your host IP throughout.

### 1.1 Enable WinRM

```powershell
Enable-PSRemoting -Force
winrm quickconfig

# Allow Basic authentication (required for non-domain environments)
winrm set winrm/config/service/auth '@{Basic="true"}'

# Verify WinRM is running
Get-Service WinRM
```

> **Note:** Forklift always uses WinRM over HTTPS (port 5986).

### 1.2 Configure WinRM HTTPS (TLS)

The certificate **must** include the host IP in the Subject Alternative Name (SAN).

```powershell
# Create self-signed certificate with IP SAN
$cert = New-SelfSignedCertificate `
    -Subject "CN=192.168.1.218" `
    -CertStoreLocation Cert:\LocalMachine\My `
    -TextExtension @("2.5.29.17={text}IPAddress=192.168.1.218") `
    -KeyUsage DigitalSignature,KeyEncipherment `
    -KeySpec KeyExchange

$cert.Thumbprint

# Create WinRM HTTPS listener
winrm create winrm/config/Listener?Address=*+Transport=HTTPS `
    "@{Hostname=`"192.168.1.218`"; CertificateThumbprint=`"$($cert.Thumbprint)`"}"

# Open firewall
netsh advfirewall firewall add rule name="WinRM HTTPS" dir=in action=allow protocol=TCP localport=5986

# Verify
winrm enumerate winrm/config/Listener
```

To export the certificate (needed for the `cacert` secret field in production):

```powershell
$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {$_.Subject -eq "CN=192.168.1.218"}
$bytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
[System.Convert]::ToBase64String($bytes)
```

### 1.3 Install iSCSI Target Server (admin prerequisite)

MTV uses the Windows iSCSI Target Server role to expose VM disks as iSCSI LUNs
during migration. This is a one-time manual step — MTV handles everything else
(creating differencing disks, targets, LUNs, ACLs, and cleanup) automatically
via WinRM.

```powershell
Install-WindowsFeature FS-iSCSITarget-Server

# Verify
Get-WindowsFeature FS-iSCSITarget-Server
```

### 1.4 Firewall Rules

```powershell
# WinRM HTTPS (required)
New-NetFirewallRule -Name "WinRM-HTTPS" -DisplayName "WinRM HTTPS" `
    -Protocol TCP -LocalPort 5986 -Action Allow

# iSCSI Target (required for disk transfer, port 3260)
New-NetFirewallRule -Name "iSCSI-Target" -DisplayName "iSCSI Target TCP 3260" `
    -Protocol TCP -LocalPort 3260 -Action Allow

# WinRM HTTP (testing/dev only -- not for production)
New-NetFirewallRule -Name "WinRM-HTTP" -DisplayName "WinRM HTTP" `
    -Protocol TCP -LocalPort 5985 -Action Allow
```

### 1.5 Enable Integration Services and Data Exchange (KVP)

Integration Services must be running on each guest VM. Data Exchange (KVP) is
required for static IP detection during migration.

**On the Hyper-V host (for each VM):**

```powershell
# Enable Data Exchange
Enable-VMIntegrationService -VMName "vm-name" -Name "Key-Value Pair Exchange"

# Verify
Get-VMIntegrationService -VMName "vm-name" |
    Where-Object { $_.Name -eq "Key-Value Pair Exchange" }
```

**Inside Linux guests (if applicable):**

```bash
# RHEL/CentOS/Fedora
sudo dnf install hyperv-daemons

# Ubuntu/Debian
sudo apt install linux-cloud-tools-common linux-tools-virtual

# Verify the KVP daemon is running
sudo systemctl status hv_kvp_daemon
```

Windows guests (Windows 8 / Server 2012 and later) have Integration Services built-in.

### 1.6 Verify Everything on the Host

```powershell
# Test WinRM
Test-WSMan -ComputerName localhost

# Verify iSCSI Target Server feature
Get-WindowsFeature FS-iSCSITarget-Server

# Check Integration Services on all VMs
Get-VM | Select-Object Name, IntegrationServicesState

# Check Data Exchange per VM
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

---

## 2. Verify Connectivity from Linux

Before creating the provider, verify that the OpenShift cluster (or your
workstation) can reach the Hyper-V host over WinRM and iSCSI.

### 2.1 Network Reachability

```bash
ping -c 3 192.168.1.218
```

### 2.2 WinRM Connectivity (port 5986)

```bash
# Basic TCP check
curl -k https://192.168.1.218:5986/wsman
```

A non-empty response (even an error XML) confirms the port is open and TLS is working.

### 2.3 iSCSI Connectivity (port 3260)

```bash
# Verify iSCSI target port is reachable
nc -zv 192.168.1.218 3260
```

If the connection succeeds, the iSCSI Target Server is listening and ready.
MTV creates and tears down iSCSI targets automatically during each migration —
no manual iSCSI configuration is needed.

---

## 3. OpenShift Cluster Prerequisites

### 3.1 Forklift (MTV) Operator

Install the Migration Toolkit for Virtualization (MTV / Forklift) operator from
OperatorHub. Verify it is running:

```bash
oc get pods -n openshift-mtv | grep forklift
```

### 3.2 OpenShift Virtualization

Install the OpenShift Virtualization operator (provides KubeVirt). This is the
target platform for migrated VMs.

```bash
oc get csv -n openshift-cnv | grep kubevirt
```

### 3.3 OpenShift Host Provider

Forklift auto-creates an OpenShift "host" provider. Verify it exists:

```bash
oc get providers -n openshift-mtv
```

You should see a provider named `host` with type `openshift` and status `Ready`.

---

## 4. Create the Hyper-V Provider

### Step 1: Create the Secret

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: hyperv-secret
  namespace: openshift-mtv
type: Opaque
stringData:
  username: "Administrator"                   # <-- Hyper-V host username (WinRM)
  password: "your-password"                   # <-- Hyper-V host password (WinRM)
  insecureSkipVerify: "true"                  # <-- For testing; use cacert in production
EOF
```

**Secret fields reference:**

| Field | Required | Description |
|-------|----------|-------------|
| `username` | Yes | Hyper-V host username (e.g., `Administrator`) — used for WinRM |
| `password` | Yes | Hyper-V host password — used for WinRM |
| `insecureSkipVerify` | No | Set to `"true"` to skip TLS verification (testing only) |
| `cacert` | No | PEM-encoded CA certificate (required if `insecureSkipVerify` is not `"true"`) |

### Step 2: Create the Provider

```bash
cat <<'EOF' | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: hyperv-source
  namespace: openshift-mtv
spec:
  type: hyperv
  url: "192.168.1.218"                        # <-- Hyper-V host IP or hostname
  secret:
    name: hyperv-secret
    namespace: openshift-mtv
EOF
```

### Step 3: Wait for the Provider to become Ready

```bash
oc get provider hyperv-source -n openshift-mtv -w
```

Wait until the `STATUS` column shows `Ready`. This typically takes 15-30 seconds.

To inspect conditions if something goes wrong:

```bash
oc get provider hyperv-source -n openshift-mtv \
    -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.message}{"\n"}{end}'
```

---

## 5. Discover Inventory

Once the provider is `Ready`, query the inventory to get the IDs you will need
for network maps, storage maps, and migration plans.

Set up shell variables:

```bash
PROVIDER_UID=$(oc get provider hyperv-source -n openshift-mtv -o jsonpath='{.metadata.uid}')
TOKEN=$(oc whoami -t)
CTRL_POD=$(oc get pods -n openshift-mtv -l control-plane=controller-manager \
    -o jsonpath='{.items[0].metadata.name}')

echo "Provider UID: $PROVIDER_UID"
echo "Controller pod: $CTRL_POD"
```

### List Networks

```bash
oc exec $CTRL_POD -n openshift-mtv -c inventory -- \
    curl -sk -H "Authorization: Bearer $TOKEN" \
    "https://localhost:8443/providers/hyperv/${PROVIDER_UID}/networks" | jq .
```

Note the `id` field (network UUID) -- you will need it for the NetworkMap.

### List Storages

```bash
oc exec $CTRL_POD -n openshift-mtv -c inventory -- \
    curl -sk -H "Authorization: Bearer $TOKEN" \
    "https://localhost:8443/providers/hyperv/${PROVIDER_UID}/storages" | jq .
```

Hyper-V always has a single storage entry with `"id": "storage-0"`.

### List VMs

```bash
oc exec $CTRL_POD -n openshift-mtv -c inventory -- \
    curl -sk -H "Authorization: Bearer $TOKEN" \
    "https://localhost:8443/providers/hyperv/${PROVIDER_UID}/vms" | jq .
```

Note the `id` field (VM UUID) -- you will need it for the Plan.

### List Disks

```bash
oc exec $CTRL_POD -n openshift-mtv -c inventory -- \
    curl -sk -H "Authorization: Bearer $TOKEN" \
    "https://localhost:8443/providers/hyperv/${PROVIDER_UID}/disks" | jq .
```

### VM Detail (optional)

To see full details for a specific VM including disks, NICs, guest networks, and concerns:

```bash
VM_UUID="<vm-uuid>"   # <-- Replace with the VM id from the list above

oc exec $CTRL_POD -n openshift-mtv -c inventory -- \
    curl -sk -H "Authorization: Bearer $TOKEN" \
    "https://localhost:8443/providers/hyperv/${PROVIDER_UID}/vms/${VM_UUID}" | jq .
```

---

## 6. Create Network and Storage Maps

### Step 4: NetworkMap

```bash
cat <<'EOF' | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: NetworkMap
metadata:
  name: hyperv-netmap
  namespace: openshift-mtv
spec:
  provider:
    source:
      name: hyperv-source
      namespace: openshift-mtv
    destination:
      name: host
      namespace: openshift-mtv
  map:
    - source:
        id: "<network-uuid>"                  # <-- From inventory (Step 5)
      destination:
        type: pod                             # pod | multus | ignored
EOF
```

**Network destination types:**

| Type | Description |
|------|-------------|
| `pod` | Default Kubernetes pod network (masquerade NAT) |
| `multus` | Multus CNI network (bridge mode) -- requires `namespace` and `name` fields |
| `ignored` | Skip this network |

> **Note:** If you plan to use `preserveStaticIPs: true` in the migration plan,
> use `multus` (bridge mode) instead of `pod`, because pod networking uses NAT
> and cannot preserve the original IP address.

**Creating a NetworkAttachmentDefinition (NAD) for bridge mode:**

If you need to use `multus` (bridge mode) for static IP preservation, first create
a NAD on the OpenShift cluster. This example creates a Linux bridge NAD:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: hyperv-bridge
  namespace: openshift-mtv
spec:
  config: |-
    {
      "cniVersion": "0.3.1",
      "name": "hyperv-bridge",
      "type": "cnv-bridge",
      "bridge": "br-hyperv",
      "macspoofchk": true,
      "ipam": {}
    }
EOF
```

Then reference it in the NetworkMap with type `multus`:

```yaml
  map:
    - source:
        id: "<network-uuid>"
      destination:
        type: multus
        namespace: openshift-mtv
        name: hyperv-bridge
```


### Step 5: StorageMap

First, find your available storage classes:

```bash
oc get storageclasses
```

Then create the map:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: StorageMap
metadata:
  name: hyperv-storagemap
  namespace: openshift-mtv
spec:
  provider:
    source:
      name: hyperv-source
      namespace: openshift-mtv
    destination:
      name: host
      namespace: openshift-mtv
  map:
    - source:
        id: "storage-0"                       # Hyper-V always uses "storage-0"
      destination:
        storageClass: "crc-csi-hostpath-provisioner"   # <-- Replace with your storage class
EOF
```

Verify both maps:

```bash
oc get networkmaps,storagemaps -n openshift-mtv
```

---

## 7. Create a Migration Plan

```bash
cat <<'EOF' | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: Plan
metadata:
  name: hyperv-test-plan
  namespace: openshift-mtv
spec:
  provider:
    source:
      name: hyperv-source
      namespace: openshift-mtv
    destination:
      name: host
      namespace: openshift-mtv
  map:
    network:
      name: hyperv-netmap
      namespace: openshift-mtv
    storage:
      name: hyperv-storagemap
      namespace: openshift-mtv
  targetNamespace: openshift-mtv               # <-- Namespace for the migrated VM
  vms:
    - id: "<vm-uuid>"                          # <-- From inventory (Step 5)
EOF
```

Wait for the plan to be `Ready`:

```bash
oc get plan hyperv-test-plan -n openshift-mtv -w
```

Check plan conditions and VM validation status:

```bash
oc get plan hyperv-test-plan -n openshift-mtv \
    -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.message}{"\n"}{end}'
```

---

## 8. Start the Migration

```bash
cat <<'EOF' | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: Migration
metadata:
  name: hyperv-test-migration
  namespace: openshift-mtv
spec:
  plan:
    name: hyperv-test-plan
    namespace: openshift-mtv
EOF
```

---

## 9. Monitoring and Verification

### Watch migration progress

```bash
oc get migration hyperv-test-migration -n openshift-mtv -w
```

### Check plan VM status

```bash
oc get plan hyperv-test-plan -n openshift-mtv -o yaml | \
    yq '.status.migration.vms'
```

### Controller logs (inventory side)

```bash
CTRL_POD=$(oc get pods -n openshift-mtv -l control-plane=controller-manager \
    -o jsonpath='{.items[0].metadata.name}')

oc logs $CTRL_POD -n openshift-mtv -c inventory | grep hyperv | tail -30
```

### Check for the migrated VM

```bash
oc get vm -n openshift-mtv
oc get vmi -n openshift-mtv
```

---

## How iSCSI Transfer Works (overview)

During migration, MTV automatically performs these steps for each VM disk:

1. **Create differencing disk** — via WinRM, creates a VHDX differencing disk
   pointing to the source VHDX. The source VM is not modified.
2. **Create iSCSI target** — creates a unique iSCSI target on the Hyper-V host
   with the differencing disk as a virtual LUN.
3. **Set initiator ACL** — restricts access to the target using the copy pod's
   IQN (iSCSI Qualified Name). No CHAP authentication (FIPS-safe).
4. **Launch populator pod** — an ephemeral `hyperv-populator` pod on OpenShift logs
   into the iSCSI target, reads the LUN as a block device, and writes it to
   the destination PVC using `qemu-img convert`.
5. **Run virt-v2v in-place** — converts the disk (guest drivers, bootloader)
   directly on the PVC.
6. **Cleanup** — removes the iSCSI target, differencing disk, and copy pod.

---

## Cleanup

To remove everything and start over:

```bash
oc delete migration hyperv-test-migration -n openshift-mtv
oc delete plan hyperv-test-plan -n openshift-mtv
oc delete storagemap hyperv-storagemap -n openshift-mtv
oc delete networkmap hyperv-netmap -n openshift-mtv
oc delete provider hyperv-source -n openshift-mtv
oc delete secret hyperv-secret -n openshift-mtv
```
