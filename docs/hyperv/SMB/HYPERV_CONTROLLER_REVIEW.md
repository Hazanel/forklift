# Hyper-V Controller-Side Code Review

**Branch:** `hyperV_libvirt`  
**Commit:** 55794aaaa  
**Scope:** Controller-side Hyper-V code in the forklift project

---

## Legend

- **[USED]** – Function is invoked at runtime and serves a purpose
- **[DEAD]** – No callers found; never invoked
- **[MIMICKED]** – Interface placeholder copied from other providers; may be no-op or minimal implementation

---

## 1. Plan Adapter: `pkg/controller/plan/adapter/hyperv/`

### 1.1 adapter.go

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `Adapter.Builder` | Returns the HyperV plan Builder for the given context | `adapter.New()` → `migration.init()` → `adapter.Builder(ctx)` | **[USED]** |
| `Adapter.Ensurer` | Returns the shared Ensurer for plan resources | `migration.init()` → `adapter.Ensurer(ctx)` | **[USED]** |
| `Adapter.Validator` | Returns the HyperV Validator for plan validation | `adapter.New()` → `validation.go` → `pAdapter.Validator(ctx)` | **[USED]** |
| `Adapter.Client` | Returns the HyperV Client (WinRM) for VM operations | `migration.init()` → `adapter.Client(ctx)` | **[USED]** |
| `Adapter.DestinationClient` | Returns the HyperV DestinationClient for post-migration cleanup | `migration.init()` → `adapter.DestinationClient(ctx)` | **[USED]** |

**Registration:** `adapter/doc.go` selects `hyperv.Adapter{}` when `provider.Type() == api.HyperV`.

---

### 1.2 builder.go

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `Builder.Secret` | No-op; SMB credentials handled by CSI at pod mount | `kubevirt.go` → `r.Builder.Secret()` during VM/secret creation | **[USED]** |
| `Builder.ConfigMap` | No-op; no per-VM config needed for HyperV | `kubevirt.go` → `r.Builder.ConfigMap()` | **[USED]** |
| `Builder.VirtualMachine` | Maps VM spec (disks, firmware, networks, CPU, memory) to KubeVirt VM | `kubevirt.go` → `r.Builder.VirtualMachine()` | **[USED]** |
| `mapDisks` | (unexported) Maps VM disks to KubeVirt volumes/disks | Called from `VirtualMachine` | **[USED]** |
| `findPVC` | (unexported) Finds PVC by disk ID annotation | Called from `mapDisks` | **[USED]** |
| `mapFirmware` | Maps BIOS/UEFI and SecureBoot | Called from `VirtualMachine` | **[USED]** |
| `mapTpm` | Maps vTPM settings | Called from `VirtualMachine` | **[USED]** |
| `mapInput` | Adds tablet input device | Called from `VirtualMachine` | **[USED]** |
| `mapNetworks` | Maps NICs to KubeVirt networks (Pod/Multus/Ignored) | Called from `VirtualMachine` | **[USED]** |
| `findNetworkMapping` | (unexported) Resolves network mapping by NIC network ID | Called from `mapNetworks` | **[USED]** |
| `mapCPU` | Maps CPU topology (or skips if instance type) | Called from `VirtualMachine` | **[USED]** |
| `mapMemory` | Maps memory size (or skips if instance type) | Called from `VirtualMachine` | **[USED]** |
| `Builder.DataVolumes` | Builds DataVolumes for VM disks (blank source for SMB) | `kubevirt.go` → `r.Builder.DataVolumes()` | **[USED]** |
| `mapDataVolume` | (unexported) Builds single DataVolume for a disk | Called from `DataVolumes` | **[USED]** |
| `getStorageClass` | (unexported) Gets storage class from mapping | Called from `mapDataVolume` | **[USED]** |
| `Builder.Tasks` | Builds progress tasks per disk | `migrator/base/migrator.go` → `r.builder.Tasks()` | **[USED]** |
| `Builder.TemplateLabels` | Returns empty labels | `kubevirt.go` → `r.Builder.TemplateLabels()` | **[USED]** |
| `Builder.ResolveDataVolumeIdentifier` | Returns disk ID from DV annotation or name | `kubevirt.go` → `r.Builder.ResolveDataVolumeIdentifier()` | **[USED]** |
| `Builder.ResolvePersistentVolumeClaimIdentifier` | Returns disk ID from PVC annotation or name | `migration.go`, `kubevirt.go` → `r.Builder.ResolvePersistentVolumeClaimIdentifier()` | **[USED]** |
| `Builder.PodEnvironment` | Builds env vars for virt-v2v pod (V2V_vmName, V2V_source, V2V_diskPath, static IPs, etc.) | `kubevirt.go` → `r.Builder.PodEnvironment()` | **[USED]** |
| `mapMacStaticIps` | (unexported) Maps MAC→IP for static IP preservation | Called from `PodEnvironment` | **[USED]** |
| `isWindows` | (unexported) Detects Windows guest OS | Called from `mapMacStaticIps`, `PodEnvironment` | **[USED]** |
| `Builder.LunPersistentVolumes` | Returns empty; no LUN support | `kubevirt.go` → `r.Builder.LunPersistentVolumes()` | **[MIMICKED]** |
| `Builder.LunPersistentVolumeClaims` | Returns empty; no LUN support | `kubevirt.go` → `r.Builder.LunPersistentVolumeClaims()` | **[MIMICKED]** |
| `Builder.SupportsVolumePopulators` | Returns false; HyperV uses CDI import | `migration.go`, `kubevirt.go` | **[USED]** |
| `Builder.PopulatorVolumes` | Returns VolumePopulatorNotSupportedError | `migration.go` → `r.builder.PopulatorVolumes()` (not reached for HyperV) | **[MIMICKED]** |
| `Builder.PopulatorTransferredBytes` | Returns error | `migration.go` → `r.builder.PopulatorTransferredBytes()` (not reached for HyperV) | **[MIMICKED]** |
| `Builder.SetPopulatorDataSourceLabels` | No-op | `migration.go` → `r.builder.SetPopulatorDataSourceLabels()` | **[MIMICKED]** |
| `Builder.GetPopulatorTaskName` | Returns "", nil | `migration.go` → `r.builder.GetPopulatorTaskName()` (not reached for HyperV) | **[MIMICKED]** |
| `Builder.PreferenceName` | Returns "", nil; no OS preference mapping | `kubevirt.go` → `r.Builder.PreferenceName()` | **[USED]** |
| `Builder.ConfigMaps` | Returns nil, nil | `kubevirt.go` → `r.Builder.ConfigMaps()` | **[USED]** |
| `Builder.Secrets` | Returns nil, nil | `kubevirt.go` → `r.Builder.Secrets()` | **[USED]** |
| `Builder.ConversionPodConfig` | Returns empty config | `kubevirt.go` → `r.Builder.ConversionPodConfig()` | **[USED]** |

---

### 1.3 client.go

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `connect` | (unexported) Establishes WinRM/HTTPS connection to Hyper-V host | Called from `Client()` and `executeCommand` | **[USED]** |
| `Client.Close` | Clears WinRM client | `migration.Run()` defer → `r.provider.Close()` | **[USED]** |
| `Client.Finalize` | No-op; no provider-specific finalization | `migration.go` → `r.provider.Finalize()` | **[USED]** |
| `Client.DetachDisks` | No-op; no LUN detachment | `migration.go` → `r.provider.DetachDisks()` | **[USED]** |
| `Client.PowerState` | Returns VM power state from inventory | `migration.go` → `r.provider.PowerState()`; `PoweredOff` calls it | **[USED]** |
| `Client.PowerOn` | No-op; not needed for cold migration | `migration.go` → `r.provider.PowerOn()` (for warm; not used for HyperV) | **[MIMICKED]** |
| `Client.PowerOff` | Powers off VM via WinRM StopVM script | `migration.go` → `r.provider.PowerOff()` | **[USED]** |
| `Client.PoweredOff` | Convenience wrapper for PowerState == Off | `migration.go` → `r.provider.PoweredOff()` | **[USED]** |
| `Client.CreateSnapshot` | Returns "", "", nil; no warm migration | `migration.go` → `r.provider.CreateSnapshot()` (warm only; not used for HyperV) | **[MIMICKED]** |
| `Client.RemoveSnapshot` | Returns "", nil | `migration.go` → `r.provider.RemoveSnapshot()` (warm only) | **[MIMICKED]** |
| `Client.CheckSnapshotReady` | Returns true, "", nil | Not directly called in migration flow; interface req | **[MIMICKED]** |
| `Client.CheckSnapshotRemove` | Returns true, nil | Not directly called in migration flow; interface req | **[MIMICKED]** |
| `Client.SetCheckpoints` | No-op | Not directly called in migration flow; interface req | **[MIMICKED]** |
| `Client.PreTransferActions` | Returns true, nil | Not directly called for HyperV cold path | **[MIMICKED]** |
| `Client.GetSnapshotDeltas` | Returns nil, nil | Not directly called for HyperV cold path | **[MIMICKED]** |
| `extractHost` | (unexported) Parses host from URL | Called from `connect` | **[USED]** |
| `executeCommand` | (unexported) Runs PowerShell via WinRM | Called from `PowerOff` | **[USED]** |
| `utf16LEEncode` | (unexported) Encodes for PowerShell -EncodedCommand | Called from `executeCommand` | **[USED]** |

---

### 1.4 destinationclient.go

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `DestinationClient.DeletePopulatorDataSource` | No-op; no populator for HyperV | `migration.go` → `r.destinationClient.DeletePopulatorDataSource()` | **[USED]** |
| `DestinationClient.SetPopulatorCrOwnership` | No-op | `migration.go` → `r.destinationClient.SetPopulatorCrOwnership()` | **[USED]** |

---

### 1.5 validator.go

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `Validator.WarmMigration` | Returns false; cold only | `validation.go` → `validator.WarmMigration()` | **[USED]** |
| `Validator.MigrationType` | Returns true for cold/empty; false otherwise | `validation.go` → `validator.MigrationType()` | **[USED]** |
| `Validator.StorageMapped` | Validates all disks have SMBPath | `validation.go` → `validator.StorageMapped()` | **[USED]** |
| `Validator.DirectStorage` | No-op; returns true | `validation.go` → `validator.DirectStorage()` | **[USED]** |
| `Validator.NetworksMapped` | Validates all connected NICs have mappings | `validation.go` → `validator.NetworksMapped()` | **[USED]** |
| `Validator.MaintenanceMode` | No-op; returns true | `validation.go` → `validator.MaintenanceMode()` | **[USED]** |
| `Validator.PodNetwork` | Ensures at most one NIC mapped to pod network | `validation.go` → `validator.PodNetwork()` | **[USED]** |
| `Validator.StaticIPs` | Validates guest network data for static IP preservation | `validation.go` → `validator.StaticIPs()` | **[USED]** |
| `Validator.UdnStaticIPs` | No-op; returns true | `validation.go` → `validator.UdnStaticIPs()` (vSphere UDN only) | **[MIMICKED]** |
| `Validator.SharedDisks` | No-op; returns true, "", "", nil | `validation.go` → `validator.SharedDisks()` | **[MIMICKED]** |
| `Validator.ChangeTrackingEnabled` | No-op; returns true | `validation.go` → `validator.ChangeTrackingEnabled()` (warm only) | **[MIMICKED]** |
| `Validator.HasSnapshot` | No-op; returns true, "", "", nil | `validation.go` → `validator.HasSnapshot()` (warm only) | **[MIMICKED]** |
| `Validator.PowerState` | No-op; returns true | `validation.go` → `validator.PowerState()` | **[USED]** |
| `Validator.VMMigrationType` | No-op; returns true | `validation.go` → `validator.VMMigrationType()` | **[USED]** |
| `Validator.InvalidDiskSizes` | Validates disk capacities > 0 | `validation.go` → `validator.InvalidDiskSizes()` | **[USED]** |
| `Validator.MacConflicts` | Checks MAC conflicts with destination VMs | `validation.go` → `validator.MacConflicts()` | **[USED]** |
| `Validator.PVCNameTemplate` | Validates PVC name template for disks | `validation.go` → `validator.PVCNameTemplate()` | **[USED]** |
| `Validator.GuestToolsInstalled` | No-op; returns true | `validation.go` → `validator.GuestToolsInstalled()` | **[MIMICKED]** |

---

## 2. Scheduler: `pkg/controller/plan/scheduler/hyperv/scheduler.go`

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `Scheduler.Next` | Returns next VM to migrate; enforces MaxInFlight across plans | `scheduler.New()` → `migration.Run()` → `r.scheduler.Next()` | **[USED]** |

**Registration:** `scheduler/doc.go` selects `hyperv.Scheduler{}` when `ctx.Source.Provider.Type() == api.HyperV`.

---

## 3. Handlers

### 3.1 Plan Handler: `pkg/controller/plan/handler/hyperv/`

| File | Function | Description | Callers | Status |
|------|----------|-------------|---------|--------|
| **handler.go** | `Handler.Watch` | Registers VM inventory watch via `watch.Ensure` | `plan/controller.go` → `h.Watch(watch)` | **[USED]** |
| **handler.go** | `Handler.Created` | On VM create; queues reconcile for referencing plans | Web client → `libweb.EventHandler.Created` | **[USED]** |
| **handler.go** | `Handler.Updated` | On VM update; queues reconcile | Web client → `libweb.EventHandler.Updated` | **[USED]** |
| **handler.go** | `Handler.Deleted` | On VM delete; queues reconcile | Web client → `libweb.EventHandler.Deleted` | **[USED]** |
| **handler.go** | `changed` | (unexported) Lists plans, enqueues if VM referenced | Called from Created/Updated/Deleted | **[USED]** |
| **doc.go** | `New` | Factory for plan handler | `plan/handler/doc.go` → `hyperv.New()` when provider is HyperV | **[USED]** |

### 3.2 Network Map Handler: `pkg/controller/map/network/handler/hyperv/`

| File | Function | Description | Callers | Status |
|------|----------|-------------|---------|--------|
| **handler.go** | `Handler.Watch` | Registers Network inventory watch | `map/network controller` → `h.Watch(watch)` | **[USED]** |
| **handler.go** | `Handler.Created` | On network create; queues reconcile | Web client → `Created` | **[USED]** |
| **handler.go** | `Handler.Updated` | On network update; queues reconcile | Web client → `Updated` | **[USED]** |
| **handler.go** | `Handler.Deleted` | On network delete; queues reconcile | Web client → `Deleted` | **[USED]** |
| **handler.go** | `changed` | Lists NetworkMaps, enqueues if network referenced | Called from Created/Updated/Deleted | **[USED]** |
| **doc.go** | `New` | Factory for network map handler | `map/network/handler/doc.go` → `hyperv.New()` | **[USED]** |

### 3.3 Storage Map Handler: `pkg/controller/map/storage/handler/hyperv/`

| File | Function | Description | Callers | Status |
|------|----------|-------------|---------|--------|
| **handler.go** | `Handler.Watch` | No-op; HyperV uses single SMB share, no storage entities | `map/storage controller` → `h.Watch(watch)` | **[USED]** |
| **doc.go** | `New` | Factory for storage map handler | `map/storage/handler/doc.go` → `hyperv.New()` | **[USED]** |

### 3.4 Host Handler: `pkg/controller/host/handler/hyperv/`

| File | Function | Description | Callers | Status |
|------|----------|-------------|---------|--------|
| **handler.go** | `Handler.Watch` | No-op; HyperV is single-host, no host-level ops | `host controller` → `h.Watch(watch)` | **[USED]** |
| **doc.go** | `New` | Factory for host handler | `host/handler/doc.go` → `hyperv.New()` | **[USED]** |

---

## 4. Builder/Controller: `pkg/controller/hyperv/`

### 4.1 builder.go

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `Labeler.ProviderLabels` | Returns labels for provider UID | `builder.go` (ProviderServer, PersistentVolume), `provider/hyperv-setup.go` (DeleteHyperVProviderServer), `deleter.go` | **[USED]** |
| `Labeler.ServerLabels` | Returns labels for provider server | `builder.go` (PV, PVC, Deployment, Service), `deleter.go` | **[USED]** |
| `Builder.prefix` | GenerateName prefix from provider name | Called from ProviderServer, PV, PVC, Deployment, Service | **[USED]** |
| `Builder.ProviderServer` | Creates HyperVProviderServer CR spec | `provider/hyperv-setup.go`, `controller.go` (indirect via Ensurer) | **[USED]** |
| `Builder.PersistentVolume` | Builds static PV for SMB CSI driver | `controller.go` → `build.PersistentVolume()` | **[USED]** |
| `Builder.PersistentVolumeClaim` | Builds PVC bound to static PV | `controller.go` → `build.PersistentVolumeClaim()` | **[USED]** |
| `Builder.Deployment` | Builds deployment for HyperV provider server | `controller.go` → `build.Deployment()` | **[USED]** |
| `Builder.PodSpec` | Builds pod spec for deployment | Called from `Deployment` | **[USED]** |
| `Builder.Service` | Builds ClusterIP service for inventory | `controller.go` → `build.Service()` | **[USED]** |
| `Builder.securityContext` | Returns security context for container | Called from `PodSpec` | **[USED]** |
| `Builder.applianceEndpoints` | Returns "true"/"false" for appliance management | Called from `PodSpec` | **[USED]** |
| `Builder.containerImage` | Returns HyperV container image from settings | Called from `PodSpec` | **[USED]** |
| `Builder.smbMountPath` | Returns SMB mount path | Called from `PodSpec` | **[USED]** |

### 4.2 controller.go

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `Add` | Registers HyperV controller with manager | `controller/controller.go` → `hyperv.Add(mgr)` | **[USED]** |
| `Reconciler.Reconcile` | Reconciles HyperVProviderServer CRs | controller-runtime | **[USED]** |
| `Reconciler.AddFinalizer` | Adds finalizer to HyperVProviderServer | Called from `Reconcile` | **[USED]** |
| `Reconciler.RemoveFinalizer` | Removes finalizer | Called from `Reconcile` | **[USED]** |
| `Reconciler.Deploy` | Creates PV, PVC, Deployment, Service for provider server | Called from `Reconcile` | **[USED]** |
| `Reconciler.Teardown` | Deletes Service, Deployment, PVC, PV | Called from `Reconcile` | **[USED]** |
| `Reconciler.managementEndpoints` | Checks if appliance management enabled | Called from `Deploy` | **[USED]** |

---
