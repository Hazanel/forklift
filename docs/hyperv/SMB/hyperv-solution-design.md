# Hyper-V Provider Solution Design

This document provides a comprehensive technical deep-dive into how the Hyper-V provider works in Forklift (MTV - Migration Toolkit for Virtualization), covering all components from the Hyper-V server export through to VM migration completion on OpenShift Virtualization.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites and Setup](#prerequisites-and-setup)
3. [Component Deep-Dive](#component-deep-dive)
4. [Storage Architecture (PV/PVC/DV)](#storage-architecture-pvpvcdv)
5. [Inventory Collection Flow](#inventory-collection-flow)
6. [Migration Execution Flow](#migration-execution-flow)
7. [virt-v2v Conversion Process](#virt-v2v-conversion-process)
8. [Data Flow Diagrams](#data-flow-diagrams)
9. [File and Code References](#file-and-code-references)

---

## Architecture Overview

The Hyper-V provider enables migration of VMs that have been **exported from Microsoft Hyper-V** to OpenShift Virtualization. Unlike vSphere migrations that connect directly to the hypervisor, Hyper-V migrations work with **pre-exported VM files** (OVF + VHDX) stored on an SMB (Windows file share).

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Hyper-V Migration Flow                            │
└─────────────────────────────────────────────────────────────────────────────┘

┌──────────────────┐     ┌──────────────────┐     ┌──────────────────────────┐
│   Hyper-V Host   │     │   Windows SMB    │     │   OpenShift Cluster      │
│                  │     │     Share        │     │                          │
│  ┌────────────┐  │     │                  │     │  ┌────────────────────┐  │
│  │    VM      │──┼──►  │  ┌────────────┐  │     │  │ HyperV Provider    │  │
│  │ (running)  │  │     │  │  vm.ovf    │  │     │  │     Server Pod     │  │
│  └────────────┘  │     │  │  vm.vhdx   │  │◄────┼──│  (inventory scan)  │  │
│                  │     │  └────────────┘  │     │  └────────────────────┘  │
│  Export-VM       │     │                  │     │           │              │
│  (PowerShell)    │     │  //server/share  │     │           ▼              │
└──────────────────┘     └──────────────────┘     │  ┌────────────────────┐  │
                                                  │  │ Forklift Controller│  │
                                                  │  │    (orchestrates)  │  │
                                                  │  └────────────────────┘  │
                                                  │           │              │
                                                  │           ▼              │
                                                  │  ┌────────────────────┐  │
                                                  │  │   virt-v2v Pod     │  │
                                                  │  │  (conversion +     │  │
                                                  │  │   disk copy)       │  │
                                                  │  └────────────────────┘  │
                                                  │           │              │
                                                  │           ▼              │
                                                  │  ┌────────────────────┐  │
                                                  │  │   KubeVirt VM      │  │
                                                  │  │   (migrated)       │  │
                                                  │  └────────────────────┘  │
                                                  └──────────────────────────┘
```

### Key Characteristics

| Aspect | Hyper-V Provider |
|--------|------------------|
| **Source Format** | Exported OVF + VHDX files |
| **Storage Access** | SMB (CIFS) file share |
| **Data Transfer** | virt-v2v reads directly from SMB mount |
| **Conversion** | Full virt-v2v (not in-place) |
| **Warm Migration** | Not supported (cold only) |

---

## Prerequisites and Setup

### 1. Hyper-V Export Process

Before migration, VMs must be exported from Hyper-V using PowerShell:

```powershell
# On the Hyper-V host
Export-VM -Name "MyVM" -Path "C:\Exports"

# This creates:
# C:\Exports\MyVM\
#   ├── MyVM.ovf           # VM configuration (OVF format)
#   ├── Virtual Hard Disks\
#   │   └── MyVM.vhdx      # Virtual disk(s)
#   └── Snapshots\         # (optional)
```

### 2. SMB Share Configuration

The exported files must be accessible via an SMB share:

```powershell
# Create SMB share on Windows
New-SmbShare -Name "VMExports" -Path "C:\Exports" -ReadAccess "Everyone"

# Or with specific permissions
New-SmbShare -Name "VMExports" -Path "C:\Exports" -FullAccess "DOMAIN\MigrationUser"
```

### 3. OpenShift Prerequisites

```bash
# Install SMB CSI Driver (required for mounting SMB shares)
# The SMB CSI driver must be installed in the cluster

# Install HyperV CRD (development only - not in standard MTV)
oc apply -f operator/config/crd/bases/forklift.konveyor.io_hypervproviderservers.yaml

# Create credentials secret
oc create secret generic hyperv-credentials \
  --from-literal=username='DOMAIN\user' \
  --from-literal=password='password' \
  -n openshift-mtv
```

### 4. Provider CR Creation

```yaml
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: hyperv-provider
  namespace: openshift-mtv
spec:
  type: hyperv
  url: "//192.168.1.100/VMExports"  # SMB share URL
  secret:
    name: hyperv-credentials
    namespace: openshift-mtv
```

---

## Component Deep-Dive

### 1. HyperVProviderServer CR

When a Hyper-V Provider is created, the **Provider Controller** creates a `HyperVProviderServer` CR:

**CRD Definition** (`pkg/apis/forklift/v1beta1/hypervserver.go`):

```go
type HyperVProviderServerSpec struct {
    Provider core.ObjectReference `json:"provider"`
}

type HyperVProviderServerStatus struct {
    Phase   string                `json:"phase,omitempty"`
    Service *core.ObjectReference `json:"service,omitempty"`
    Conditions                    `json:",inline"`
}
```

### 2. HyperV Server Pod Rollout Flow

When a user creates a HyperV Provider CR, the following chain of events creates the provider server pod:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 1. USER creates Provider CR (type: hyperv)                                  │
│    kubectl apply -f hyperv-provider.yaml                                    │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 2. PROVIDER CONTROLLER (pkg/controller/provider/controller.go)              │
│    - Watches Provider CRs                                                   │
│    - Detects type: hyperv                                                   │
│    - Calls ensureProviderServer() → EnsureHyperVProviderServer()           │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 3. HYPERV-SETUP (pkg/controller/provider/hyperv-setup.go)                   │
│    - EnsureHyperVProviderServer() creates HyperVProviderServer CR          │
│    - Uses hyperv.Builder{}.ProviderServer(provider)                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 4. HYPERV CONTROLLER (pkg/controller/hyperv/controller.go)                  │
│    - Watches HyperVProviderServer CRs                                       │
│    - Reconcile() calls Deploy()                                            │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 5. DEPLOY creates these resources (pkg/controller/hyperv/builder.go):       │
│    - PersistentVolume (static PV for SMB share)                            │
│    - PersistentVolumeClaim (bound to the PV)                               │
│    - Deployment (hyperv-provider-server pod with SMB mount)                │
│    - Service (for inventory API access)                                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Summary Table:**

| Step | Component | File | Action |
|------|-----------|------|--------|
| 1 | User | - | Creates `Provider` CR with `type: hyperv` |
| 2 | Provider Controller | `pkg/controller/provider/controller.go` | Detects HyperV, calls `ensureProviderServer()` |
| 3 | HyperV Setup | `pkg/controller/provider/hyperv-setup.go` | Creates `HyperVProviderServer` CR |
| 4 | HyperV Controller | `pkg/controller/hyperv/controller.go` | Watches `HyperVProviderServer`, calls `Deploy()` |
| 5 | HyperV Builder | `pkg/controller/hyperv/builder.go` | Creates PV, PVC, Deployment, Service |

The **hyperv-provider-server pod** image is configured via the `HYPERV_PROVIDER_SERVER_IMAGE` environment variable (set by the operator or patched manually during development).

### 3. HyperV Server Controller

**Location**: `pkg/controller/hyperv/controller.go`

The HyperV Server Controller watches `HyperVProviderServer` CRs and manages:

```go
func (r *Reconciler) Deploy(ctx context.Context, hyperv *api.HyperVProviderServer) (err error) {
    // 1. Get the Provider CR
    provider := &api.Provider{}
    r.Get(ctx, ..., provider)
    
    // 2. Get the credentials secret
    secret := &v1.Secret{}
    r.Get(ctx, ..., secret)
    
    // 3. Create PV for SMB mount
    pv := build.PersistentVolume(provider, secret)
    pv, err = ensure.PersistentVolume(ctx, pv)
    
    // 4. Create PVC bound to PV
    pvc := build.PersistentVolumeClaim(provider, pv)
    pvc, err = ensure.PersistentVolumeClaim(ctx, pvc)
    
    // 5. Create Deployment with SMB mount
    deployment := build.Deployment(provider, pvc)
    err = ensure.Deployment(ctx, deployment)
    
    // 6. Create Service for inventory access
    service := build.Service(provider)
    service, err = ensure.Service(ctx, service)
}
```

### 4. HyperV Provider Server Pod

**Location**: `cmd/hyperv-provider-server/main.go`

The provider server pod:
- Mounts the SMB share at `/hyperv`
- Scans for OVF files
- Exposes inventory via REST API

```go
func main() {
    Settings := &settings.ProviderSettings{
        DefaultCatalogPath: "/hyperv",  // SMB mount point
    }
    
    router := gin.Default()
    
    // Inventory endpoints
    inventoryHandler := api.InventoryHandler{
        Settings:     Settings,
        ProviderType: inventory.ProviderTypeHyperV,
    }
    inventoryHandler.AddRoutes(router)  // /vms, /networks, /disks
    
    router.Run(":8080")
}
```

---

## Storage Architecture (PV/PVC/DV)

The Hyper-V provider uses a **two-tier storage architecture**:

### Tier 1: SMB Share Access (Read-Only)

Used by the Provider Server pod for inventory scanning:

```
┌─────────────────────────────────────────────────────────────────┐
│                  SMB Share Access Architecture                   │
└─────────────────────────────────────────────────────────────────┘

┌──────────────┐     ┌──────────────┐     ┌──────────────────────┐
│  SMB Share   │     │   Static PV  │     │  Provider Server Pod │
│ //srv/share  │◄────│  (smb.csi)   │◄────│     /hyperv mount    │
└──────────────┘     └──────────────┘     └──────────────────────┘
                            │
                            ▼
                     ┌──────────────┐
                     │  Static PVC  │
                     │  (ReadOnly)  │
                     └──────────────┘
```

**PV Definition** (`pkg/controller/hyperv/builder.go`):

```go
func (r *Builder) PersistentVolume(provider *api.Provider, secret *core.Secret) *core.PersistentVolume {
    return &core.PersistentVolume{
        Spec: core.PersistentVolumeSpec{
            Capacity: core.ResourceList{
                core.ResourceStorage: resource.MustParse("10Gi"),
            },
            AccessModes: []core.PersistentVolumeAccessMode{
                core.ReadOnlyMany,  // Read-only access
            },
            PersistentVolumeSource: core.PersistentVolumeSource{
                CSI: &core.CSIPersistentVolumeSource{
                    Driver:       "smb.csi.k8s.io",
                    VolumeHandle: string(provider.UID),
                    VolumeAttributes: map[string]string{
                        "source": "//server/share",
                    },
                    NodeStageSecretRef: &core.SecretReference{
                        Name:      secret.Name,
                        Namespace: secret.Namespace,
                    },
                },
            },
        },
    }
}
```

### Tier 2: Migration Target Storage (Read-Write)

Used by virt-v2v pod and final VM:

```
┌─────────────────────────────────────────────────────────────────┐
│                Migration Storage Architecture                    │
└─────────────────────────────────────────────────────────────────┘

For EACH disk in the source VM:

┌──────────────────┐     ┌──────────────────┐     ┌────────────────┐
│   DataVolume     │────►│       PVC        │────►│   virt-v2v     │
│  (Blank source)  │     │ (target storage) │     │   writes to    │
└──────────────────┘     └──────────────────┘     └────────────────┘
                                                          │
                                                          ▼
                                                  ┌────────────────┐
                                                  │   KubeVirt VM  │
                                                  │   (uses PVC)   │
                                                  └────────────────┘
```

**DataVolume Creation** (`pkg/controller/plan/adapter/ovfbase/builder.go`):

```go
func (r *Builder) mapDataVolume(disk ovfmodel.Disk, destination api.DestinationStorage, 
                                dvTemplate *cdi.DataVolume) (*cdi.DataVolume, error) {
    dvSource := cdi.DataVolumeSource{
        Blank: &cdi.DataVolumeBlankImage{},  // Empty disk - virt-v2v will populate
    }
    
    dvSpec := cdi.DataVolumeSpec{
        Source: &dvSource,
        Storage: &cdi.StorageSpec{
            Resources: core.VolumeResourceRequirements{
                Requests: core.ResourceList{
                    core.ResourceStorage: *resource.NewQuantity(diskSize, resource.BinarySI),
                },
            },
            StorageClassName: &destination.StorageClass,
        },
    }
    
    dv := dvTemplate.DeepCopy()
    dv.Spec = dvSpec
    dv.Annotations[planbase.AnnDiskSource] = getDiskFullPath(&disk)
    return dv, nil
}
```

### Tier 3: virt-v2v Pod SMB Access

The virt-v2v pod also needs SMB access to read source disks:

```go
// pkg/controller/plan/kubevirt.go
case api.HyperV:
    // HyperV: Static SMB CSI PV/PVC
    pv := r.BuildPVForSMB(vm)
    pv, err = r.EnsurePVForSMB(pv)
    pvc := r.BuildPVCForSMB(pv, vm)
    pvc, err = r.EnsureProviderStoragePVC(pvc, api.HyperV)
    
    // Mount in virt-v2v pod
    volumes = append(volumes, core.Volume{
        Name: "hyperv-storage",
        VolumeSource: core.VolumeSource{
            PersistentVolumeClaim: &core.PersistentVolumeClaimVolumeSource{
                ClaimName: pvc.Name,
            },
        },
    })
    mounts = append(mounts, core.VolumeMount{
        Name:      "hyperv-storage",
        MountPath: "/hyperv",  // Source files accessible here
    })
```

---

## Inventory Collection Flow

### 1. Scanning Process

**Location**: `cmd/provider-common/inventory/scan.go`

```go
func ScanForAppliances(path string, providerType string) ([]ovf.Envelope, []string) {
    // Find .ovf files (HyperV exports don't use .ova archives)
    ovaFiles, ovfFiles, err := findApplianceFiles(path)
    
    // Process standalone .ovf files
    for _, ovfFile := range ovfFiles {
        // Skip files still being copied (modified in last 30s)
        if !isFileComplete(ovfFile) {
            continue
        }
        
        // Parse OVF XML
        xmlStruct, err := ovf.ReadEnvelope(ovfFile)
        envelopes = append(envelopes, *xmlStruct)
        filesPath = append(filesPath, ovfFile)
    }
    
    return envelopes, filesPath
}
```

### 2. OVF Parsing

**Location**: `cmd/provider-common/ovf/ovf.go`

```go
func ReadEnvelope(ovfPath string) (*Envelope, error) {
    file, _ := os.Open(ovfPath)
    envelope := &Envelope{}
    decoder := xml.NewDecoder(file)
    decoder.Decode(envelope)
    return envelope, nil
}

// OVF structure
type Envelope struct {
    VirtualSystem  []VirtualSystem `xml:"VirtualSystem"`
    DiskSection    DiskSection     `xml:"DiskSection"`
    NetworkSection NetworkSection  `xml:"NetworkSection"`
    References     References      `xml:"References"`
}
```

### 3. VM Struct Conversion

**Location**: `cmd/provider-common/inventory/convert.go`

```go
func ConvertToVmStruct(envelope []ovf.Envelope, ovaPath []string) []ovf.VM {
    for i, vmXml := range envelope {
        for _, virtualSystem := range vmXml.VirtualSystem {
            newVM := ovf.VM{
                OvfPath:      ovaPath[i],
                ExportSource: ovf.GuessSource(vmXml),
                Name:         virtualSystem.Name,
                OsType:       virtualSystem.OperatingSystemSection.OsType,
            }
            
            // Parse hardware items
            for _, item := range virtualSystem.HardwareSection.Items {
                switch item.ResourceType {
                case ResourceTypeProcessor:
                    newVM.CpuCount = item.VirtualQuantity
                case ResourceTypeMemory:
                    newVM.MemoryMB = item.VirtualQuantity
                case ResourceTypeEthernetAdapter:
                    newVM.NICs = append(newVM.NICs, ovf.NIC{...})
                }
            }
            
            // Parse disk references
            for j, disk := range vmXml.DiskSection.Disks {
                name := envelope[i].References.File[j].Href  // e.g., "MyVM.vhdx"
                newVM.Disks = append(newVM.Disks, ovf.VmDisk{
                    FilePath: GetDiskPath(ovaPath[i]),
                    Capacity: disk.Capacity,
                    Name:     name,
                })
            }
            
            vms = append(vms, newVM)
        }
    }
    return vms
}
```

### 4. Inventory API

**Location**: `cmd/provider-common/api/inventory.go`

```go
func (h InventoryHandler) AddRoutes(e *gin.Engine) {
    e.GET("/vms", h.VMs)
    e.GET("/networks", h.Networks)
    e.GET("/disks", h.Disks)
    e.GET("/test_connection", h.TestConnection)
}

func (h InventoryHandler) VMs(ctx *gin.Context) {
    envelopes, paths := inventory.ScanForAppliances(h.Settings.CatalogPath, h.ProviderType)
    ctx.JSON(http.StatusOK, inventory.ConvertToVmStruct(envelopes, paths))
}
```

### 5. Controller Inventory Access

**Location**: `pkg/controller/provider/container/ovfbase/client.go`

```go
func (r *Client) Connect(provider *api.Provider) error {
    service := provider.Status.Service
    svcURL := fmt.Sprintf("http://%s.%s.svc.cluster.local:8080", 
                          service.Name, service.Namespace)
    
    // Test connection
    testURL := svcURL + "/test_connection"
    status, _ := client.Get(testURL, &res)
    
    r.serviceURL = svcURL
    return nil
}

func (r *Client) List(path string, list interface{}) error {
    url := r.serviceURL + "/" + path  // e.g., /vms
    r.client.Get(url.String(), list)
    return nil
}
```

---

## Migration Execution Flow

### Phase 1: Plan Validation

```go
// pkg/controller/plan/adapter/ovfbase/validator.go
type Validator struct {
    *plancontext.Context
}

// Validates VM exists in inventory, network/storage mappings are valid
```

### Phase 2: DataVolume Creation

For each VM disk, a DataVolume with `Blank` source is created:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: vm-disk-0
  annotations:
    forklift.konveyor.io/disk-source: "/hyperv/MyVM/Virtual Hard Disks::MyVM.vhdx"
spec:
  source:
    blank: {}  # Empty - virt-v2v will populate
  storage:
    storageClassName: ocs-storagecluster-ceph-rbd
    resources:
      requests:
        storage: 50Gi
```

### Phase 3: virt-v2v Pod Creation

**Location**: `pkg/controller/plan/kubevirt.go`

```go
func (r *KubeVirt) getVirtV2vPod(vm *plan.VMStatus, ...) (*core.Pod, error) {
    // Build volume mounts
    volumes, mounts, devices, _ := r.podVolumeMounts(vmVolumes, ...)
    
    // Add SMB storage mount for HyperV
    case api.HyperV:
        pv := r.BuildPVForSMB(vm)
        pv, _ = r.EnsurePVForSMB(pv)
        pvc := r.BuildPVCForSMB(pv, vm)
        pvc, _ = r.EnsureProviderStoragePVC(pvc, api.HyperV)
        
        volumes = append(volumes, core.Volume{
            Name: "hyperv-storage",
            VolumeSource: core.VolumeSource{
                PersistentVolumeClaim: &core.PersistentVolumeClaimVolumeSource{
                    ClaimName: pvc.Name,
                },
            },
        })
        mounts = append(mounts, core.VolumeMount{
            Name:      "hyperv-storage",
            MountPath: "/hyperv",
        })
    
    // Build pod spec
    pod := &core.Pod{
        Spec: core.PodSpec{
            Containers: []core.Container{{
                Name:         "virt-v2v",
                Image:        virtV2vImage,
                VolumeMounts: mounts,
                VolumeDevices: devices,
                Env: []core.EnvVar{
                    {Name: "V2V_vmName", Value: vm.Name},
                    {Name: "V2V_diskPath", Value: "/hyperv/MyVM"},
                    {Name: "V2V_source", Value: "ova"},
                },
            }},
            Volumes: volumes,
        },
    }
    return pod, nil
}
```

### Phase 4: Conversion Progress Monitoring

**Location**: `pkg/controller/plan/migration.go`

```go
case api.PhaseConvertGuest, api.PhaseCopyDisksVirtV2V:
    // Update progress from virt-v2v-monitor metrics
    err = r.updateConversionProgress(vm, step)
    
    // Fetch config from conversion pod
    pod, _ := r.kubevirt.GetGuestConversionPod(vm)
    if pod.Status.Phase == core.PodRunning {
        r.kubevirt.UpdateVmByConvertedConfig(vm, pod, step)
    }
    
    if step.MarkedCompleted() && !step.HasError() {
        r.NextPhase(vm)
    }
```

---

## virt-v2v Conversion Process

### 1. Entry Point

**Location**: `cmd/virt-v2v/entrypoint.go`

```go
func main() {
    env := &config.AppConfig{}
    env.Load()
    
    convert, _ := conversion.NewConversion(env)
    
    // For HyperV/OVA: Run full virt-v2v (not in-place)
    if !convert.IsInPlace {
        convert.RunVirtV2v()  // Copies AND converts
    }
    
    // Run inspection
    convert.RunVirtV2VInspection()
    
    // Run customization
    convert.RunCustomize(inspection.OS)
    
    // Start server for controller communication
    if convert.IsLocalMigration {
        server.Start()
    }
}
```

### 2. virt-v2v Command Construction

**Location**: `pkg/virt-v2v/conversion/conversion.go`

```go
func (c *Conversion) virtV2vOVAArgs(cmd utils.CommandBuilder) {
    cmd.AddArg("-i", "ova")           // Input mode: OVA/OVF
    cmd.AddPositional(c.DiskPath)     // Path to OVF directory: /hyperv/MyVM
}

func (c *Conversion) RunVirtV2v() error {
    v2vCmdBuilder := c.CommandBuilder.New("virt-v2v")
    
    // Common args
    v2vCmdBuilder.
        AddFlag("-v").                           // Verbose
        AddFlag("-x").                           // Debug
        AddArg("-o", "kubevirt").                // Output: KubeVirt format
        AddArg("-os", c.Workdir).                // Output directory: /var/tmp/v2v
        AddArg("-on", c.NewVmName)               // Output VM name
    
    // Source-specific args
    switch c.Source {
    case config.OVA:  // HyperV uses OVA mode
        c.virtV2vOVAArgs(v2vCmdBuilder)
    }
    
    v2vCmd := v2vCmdBuilder.Build()
    // Resulting command:
    // virt-v2v -v -x -o kubevirt -os /var/tmp/v2v -on myvm -i ova /hyperv/MyVM
    
    return v2vCmd.Run()
}
```

### 3. What virt-v2v Does

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        virt-v2v Conversion Process                          │
└─────────────────────────────────────────────────────────────────────────────┘

Step 1: Parse OVF
┌──────────────────┐
│  /hyperv/MyVM/   │
│    MyVM.ovf      │───► Parse VM configuration
│    MyVM.vhdx     │     (CPU, memory, disks, networks)
└──────────────────┘

Step 2: Read Source Disk
┌──────────────────┐
│  MyVM.vhdx       │───► Read VHDX format
│  (VHDX format)   │     Supports dynamic/differencing disks
└──────────────────┘

Step 3: Convert Disk Format
┌──────────────────┐     ┌──────────────────┐
│  VHDX            │────►│  RAW             │
│  (Windows)       │     │  (KubeVirt)      │
└──────────────────┘     └──────────────────┘

Step 4: Install Drivers
┌──────────────────────────────────────────┐
│  Guest OS Modifications:                  │
│  - Install virtio drivers (Windows)       │
│  - Remove Hyper-V integration services    │
│  - Update boot configuration              │
│  - Configure for KVM/QEMU                 │
└──────────────────────────────────────────┘

Step 5: Write to Target PVC
┌──────────────────┐     ┌──────────────────┐
│  Converted       │────►│  /mnt/disks/     │
│  RAW disk        │     │  disk0/disk.img  │
└──────────────────┘     │  (mounted PVC)   │
                         └──────────────────┘
```

### 4. Disk Handling in virt-v2v Pod

**Location**: `pkg/virt-v2v/conversion/disk.go`

```go
func NewDisk(cfg *config.AppConfig, diskPath string) (*Disk, error) {
    // Disks are mounted at /mnt/disks/disk0, /mnt/disks/disk1, etc.
    // These are the target PVCs (DataVolumes)
    
    disk := Disk{
        Path:       diskPath,  // e.g., /mnt/disks/disk0/disk.img
        IsBlockDev: isBlockDev,
    }
    
    // Create symlink for virt-v2v naming convention
    // /var/tmp/v2v/myvm-sda -> /mnt/disks/disk0/disk.img
    link, _ := disk.createLink()
    disk.Link = link
    
    return &disk, nil
}
```

### 5. Progress Monitoring

**Location**: `cmd/virt-v2v-monitor/virt-v2v-monitor.go`

The virt-v2v-monitor parses virt-v2v stdout and exposes Prometheus metrics:

```
# HELP v2v_disk_transfers Disk transfer progress
# TYPE v2v_disk_transfers gauge
v2v_disk_transfers{disk_id="1"} 45.5
v2v_disk_transfers{disk_id="2"} 0
```

The controller polls these metrics:

```go
// pkg/controller/plan/migration.go
func (r *Migration) updateConversionProgressV2vMonitor(pod *core.Pod, step *plan.Step) error {
    url := fmt.Sprintf("http://%s:2112/metrics", pod.Status.PodIP)
    resp, _ := http.Get(url)
    
    // Parse: v2v_disk_transfers{disk_id="1"} 45.5
    matches := diskRegex.FindAllStringSubmatch(string(body), -1)
    for _, match := range matches {
        diskNumber, _ := strconv.ParseUint(match[1], 10, 0)
        progress, _ := strconv.ParseFloat(match[2], 64)
        
        task := step.Tasks[diskNumber-1]
        task.Progress.Completed = int64(float64(task.Progress.Total) * progress / 100)
    }
}
```

---

## Data Flow Diagrams

### Complete Migration Data Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Complete Hyper-V Migration Data Flow                     │
└─────────────────────────────────────────────────────────────────────────────┘

1. EXPORT (Manual - Windows)
   ┌────────────────┐
   │ Hyper-V Host   │
   │ Export-VM      │───────────────────────────┐
   └────────────────┘                           │
                                                ▼
2. STORAGE                              ┌───────────────────┐
                                        │   SMB Share       │
                                        │ //server/VMShare  │
                                        │   ├── MyVM.ovf    │
                                        │   └── MyVM.vhdx   │
                                        └───────────────────┘
                                                │
3. PROVIDER SETUP                               │
   ┌────────────────┐                           │
   │ Provider CR    │                           │
   │ type: hyperv   │                           │
   │ url: //srv/... │                           │
   └────────────────┘                           │
         │                                      │
         ▼                                      │
   ┌────────────────┐     ┌─────────────┐       │
   │ HyperVProvider │────►│ PV (SMB CSI)│◄──────┘
   │ Server CR      │     └─────────────┘
   └────────────────┘           │
         │                      ▼
         │              ┌─────────────┐
         │              │ PVC (RO)    │
         │              └─────────────┘
         │                      │
         ▼                      ▼
   ┌────────────────────────────────────┐
   │     Provider Server Pod            │
   │  ┌──────────────────────────────┐  │
   │  │ /hyperv (SMB mount)          │  │
   │  │   ├── MyVM.ovf               │  │
   │  │   └── MyVM.vhdx              │  │
   │  └──────────────────────────────┘  │
   │                                    │
   │  Scans OVF → Exposes /vms API      │
   └────────────────────────────────────┘
                    │
4. INVENTORY        │ HTTP GET /vms
                    ▼
   ┌────────────────────────────────────┐
   │     Forklift Controller            │
   │  ┌──────────────────────────────┐  │
   │  │ Inventory Collector          │  │
   │  │ (ovfbase/collector.go)       │  │
   │  └──────────────────────────────┘  │
   │                │                   │
   │                ▼                   │
   │  ┌──────────────────────────────┐  │
   │  │ Inventory DB                 │  │
   │  │ VMs, Networks, Disks         │  │
   │  └──────────────────────────────┘  │
   └────────────────────────────────────┘
                    │
5. PLAN CREATION    │
                    ▼
   ┌────────────────────────────────────┐
   │            Plan CR                 │
   │  source: hyperv-provider           │
   │  vms: [{id: "abc123", name: MyVM}] │
   │  map:                              │
   │    network: hyperv-netmap          │
   │    storage: hyperv-storagemap      │
   └────────────────────────────────────┘
                    │
6. MIGRATION START  │
                    ▼
   ┌────────────────────────────────────┐
   │         Migration CR               │
   │  plan: hyperv-migration            │
   │  cutover: <timestamp>              │
   └────────────────────────────────────┘
                    │
7. DV CREATION      │
                    ▼
   ┌────────────────────────────────────┐
   │      DataVolume (per disk)         │
   │  source: blank                     │
   │  storage: 50Gi                     │
   │  storageClass: ocs-rbd             │
   └────────────────────────────────────┘
         │
         ▼
   ┌────────────────────────────────────┐
   │            Target PVC              │
   │  (bound, empty, waiting)           │
   └────────────────────────────────────┘
                    │
8. VIRT-V2V POD     │
                    ▼
   ┌────────────────────────────────────────────────────────────────┐
   │                    virt-v2v Pod                                │
   │  ┌──────────────────────────────────────────────────────────┐  │
   │  │ Volume Mounts:                                           │  │
   │  │   /hyperv (SMB) ─────────────────────────────────────┐   │  │
   │  │   /mnt/disks/disk0 (target PVC) ◄────────────────┐   │   │  │
   │  └──────────────────────────────────────────────────│───│───┘  │
   │                                                     │   │      │
   │  ┌──────────────────────────────────────────────────│───│───┐  │
   │  │ virt-v2v -i ova /hyperv/MyVM                     │   │   │  │
   │  │                                                  │   │   │  │
   │  │   1. Read OVF ◄──────────────────────────────────┼───┘   │  │
   │  │   2. Read VHDX ◄─────────────────────────────────┘       │  │
   │  │   3. Convert VHDX → RAW                                  │  │
   │  │   4. Install virtio drivers                              │  │
   │  │   5. Write to /mnt/disks/disk0/disk.img ─────────────────┼──┼──►
   │  └──────────────────────────────────────────────────────────┘  │
   │                                                                │
   │  ┌──────────────────────────────────────────────────────────┐  │
   │  │ virt-v2v-monitor                                         │  │
   │  │   Exposes :2112/metrics                                  │  │
   │  │   v2v_disk_transfers{disk_id="1"} 75.5                   │  │
   │  └──────────────────────────────────────────────────────────┘  │
   └────────────────────────────────────────────────────────────────┘
                    │
9. VM CREATION      │
                    ▼
   ┌────────────────────────────────────┐
   │       KubeVirt VirtualMachine      │
   │  spec:                             │
   │    template:                       │
   │      spec:                         │
   │        volumes:                    │
   │        - persistentVolumeClaim:    │
   │            claimName: vm-disk-0    │
   │        domain:                     │
   │          cpu: {cores: 4}           │
   │          memory: {guest: 8Gi}      │
   │          devices:                  │
   │            disks:                  │
   │            - disk: {bus: virtio}   │
   │            interfaces:             │
   │            - masquerade: {}        │
   └────────────────────────────────────┘
```

---

## File and Code References

### Core Components

| Component | Location | Purpose |
|-----------|----------|---------|
| HyperV Provider Server | `cmd/hyperv-provider-server/main.go` | Inventory API server |
| HyperV Controller | `pkg/controller/hyperv/controller.go` | Manages HyperVProviderServer lifecycle |
| HyperV Builder | `pkg/controller/hyperv/builder.go` | Builds PV/PVC/Deployment/Service |
| HyperV Ensurer | `pkg/controller/hyperv/ensurer.go` | Ensures resources exist |
| HyperV Deleter | `pkg/controller/hyperv/deleter.go` | Cleans up resources |
| Provider Setup | `pkg/controller/provider/hyperv-setup.go` | Creates HyperVProviderServer from Provider |

### Inventory Components

| Component | Location | Purpose |
|-----------|----------|---------|
| OVF Scanner | `cmd/provider-common/inventory/scan.go` | Scans for OVF files |
| OVF Parser | `cmd/provider-common/ovf/ovf.go` | Parses OVF XML |
| VM Converter | `cmd/provider-common/inventory/convert.go` | Converts OVF to VM structs |
| Inventory API | `cmd/provider-common/api/inventory.go` | REST endpoints |
| Inventory Client | `pkg/controller/provider/container/ovfbase/client.go` | Controller's inventory client |
| Inventory Collector | `pkg/controller/provider/container/ovfbase/collector.go` | Collects inventory into DB |

### Plan Adapter Components

| Component | Location | Purpose |
|-----------|----------|---------|
| HyperV Adapter | `pkg/controller/plan/adapter/hyperv/adapter.go` | Type aliases to ovfbase |
| OVF Base Adapter | `pkg/controller/plan/adapter/ovfbase/adapter.go` | Shared OVA/HyperV adapter |
| OVF Base Builder | `pkg/controller/plan/adapter/ovfbase/builder.go` | Builds DVs, VM specs |
| OVF Base Validator | `pkg/controller/plan/adapter/ovfbase/validator.go` | Validates plans |

### virt-v2v Components

| Component | Location | Purpose |
|-----------|----------|---------|
| Entrypoint | `cmd/virt-v2v/entrypoint.go` | Main virt-v2v orchestration |
| Conversion | `pkg/virt-v2v/conversion/conversion.go` | Builds virt-v2v commands |
| Config | `pkg/virt-v2v/config/variables.go` | Environment variables |
| Disk Handler | `pkg/virt-v2v/conversion/disk.go` | Disk path management |
| Monitor | `cmd/virt-v2v-monitor/virt-v2v-monitor.go` | Progress metrics |

### KubeVirt Integration

| Component | Location | Purpose |
|-----------|----------|---------|
| KubeVirt Client | `pkg/controller/plan/kubevirt.go` | Creates virt-v2v pods, VMs |
| SMB PV Builder | `pkg/controller/plan/kubevirt.go:BuildPVForSMB` | Creates SMB PV for virt-v2v |
| SMB PVC Builder | `pkg/controller/plan/kubevirt.go:BuildPVCForSMB` | Creates SMB PVC |

### CRD Definitions

| CRD | Location |
|-----|----------|
| HyperVProviderServer | `pkg/apis/forklift/v1beta1/hypervserver.go` |
| Provider | `pkg/apis/forklift/v1beta1/provider.go` |
| Plan | `pkg/apis/forklift/v1beta1/plan.go` |

---

## Key Differences from Other Providers

| Aspect | vSphere | oVirt | OVA | HyperV |
|--------|---------|-------|-----|--------|
| **Connection** | Direct API | Direct API | NFS share | SMB share |
| **Data Transfer** | VDDK/CDI | imageio/CDI | virt-v2v | virt-v2v |
| **Warm Migration** | Yes | Yes | No | No |
| **Live Migration** | Limited | No | No | No |
| **virt-v2v Mode** | -i libvirt | -i libvirt | -i ova | -i ova |
| **Disk Format** | VMDK | qcow2/raw | VMDK | VHDX |
| **CSI Driver** | N/A | N/A | NFS | SMB |

---

## Troubleshooting

### Common Issues

1. **SMB Mount Failures**
   ```bash
   # Check SMB CSI driver is installed
   oc get csidrivers | grep smb
   
   # Check PV/PVC status
   oc get pv,pvc -n openshift-mtv
   
   # Check provider server pod logs
   oc logs -n openshift-mtv deployment/hyperv-<provider>
   ```

2. **Inventory Empty**
   ```bash
   # Check OVF files are accessible
   oc exec -n openshift-mtv <provider-pod> -- ls -la /hyperv/
   
   # Check OVF parsing
   oc exec -n openshift-mtv <provider-pod> -- cat /hyperv/MyVM/MyVM.ovf
   ```

3. **virt-v2v Failures**
   ```bash
   # Check virt-v2v pod logs
   oc logs -n <target-ns> <virt-v2v-pod>
   
   # Check disk mounts
   oc exec -n <target-ns> <virt-v2v-pod> -- ls -la /hyperv/
   oc exec -n <target-ns> <virt-v2v-pod> -- ls -la /mnt/disks/
   ```

4. **Progress Not Updating**
   ```bash
   # Check virt-v2v-monitor metrics
   oc exec -n <target-ns> <virt-v2v-pod> -- curl localhost:2112/metrics
   ```

---

## Summary

The Hyper-V provider enables migration of exported Hyper-V VMs through:

1. **SMB-based file access** using the Kubernetes SMB CSI driver
2. **OVF parsing** to build inventory from exported VM configurations
3. **Full virt-v2v conversion** that reads VHDX disks and converts them to KubeVirt-compatible RAW format
4. **Driver injection** to replace Hyper-V integration services with virtio drivers
5. **KubeVirt VM creation** with the converted disks attached as PVCs

The architecture shares significant code with the OVA provider through the `ovfbase` package, differing primarily in the storage access method (SMB vs NFS) and disk format (VHDX vs VMDK).

