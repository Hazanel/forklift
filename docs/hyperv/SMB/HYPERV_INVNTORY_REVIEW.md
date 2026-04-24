# Hyper-V Code Review: Inventory, Web, and Model

**Branch:** `hyperV_libvirt`  
**Commit:** 55794aaaa  
**Scope:** Provider container (inventory collector), provider model, provider web (REST handlers), provider validation

---

## Summary

| Classification | Count |
|----------------|-------|
| **[USED]**     | Functions actively called from the codebase |
| **[DEAD]**     | Exported but never called; safe to remove |
| **[MIMICKED]** | Pattern copied from other providers but not invoked for HyperV |

---

## 1. Provider Container (Inventory Collector)

### collector.go

| Function/Method | Description | Callers | Status |
|----------------|-------------|---------|--------|
| `SortNICsByGuestNetworkOrder(vm)` | Reorders vm.NICs to match MAC order of GuestNetworks. | `collector.convertVM()` (line 448) | **[USED]** |
| `New(db, provider, secret)` | Creates HyperV collector. | `container/doc.go:37` via `container.Build()` | **[USED]** |
| `(r *Collector) Name()` | Returns collector identifier. | libcontainer interface | **[MIMICKED]** |
| `(r *Collector) Owner()` | Returns provider CR. | `container.Replace()`, `provider.go:65` | **[USED]** |
| `(r *Collector) DB()` | Returns DB client. | All web handlers, `validation.go:576` | **[USED]** |
| `(r *Collector) Reset()` | Clears parity. | libcontainer interface | **[MIMICKED]** |
| `(r *Collector) HasParity()` | Returns sync completed. | `base.go:42`, `validation.go:477` | **[USED]** |
| `(r *Collector) Test()` | Tests connection. | `validation.go:422` | **[USED]** |
| `(r *Collector) Version()` | NO-OP for HyperV. | libcontainer interface | **[MIMICKED]** |
| `(r *Collector) Follow()` | Not implemented. | libcontainer interface | **[MIMICKED]** |
| `(r *Collector) Start()` | Starts collector. | `lib/inventory/container` Add/Replace | **[USED]** |
| `(r *Collector) Shutdown()` | Stops collector. | `container.Replace()` | **[USED]** |
| `(r *Collector) HyperVCredentials()` | WinRM credentials. | **None** | **[DEAD]** |
| `(r *Collector) SMBCredentials()` | SMB credentials. | **None** | **[DEAD]** |
| `(r *Collector) SMBPath()` | SMB mount path. | **None** | **[DEAD]** |
| `(r *Collector) SMBUrl()` | SMB share URL. | **None** | **[DEAD]** |
| `(r *Client) Connect()` | Connects to provider server. | Test, run | **[USED]** |
| `(r *Client) List()` | Fetches collection. | loadNetworks, loadStorages, loadVMs | **[USED]** |

### watch.go

| Function/Method | Description | Callers | Status |
|----------------|-------------|---------|--------|
| `VMEventHandler.Started()` | Watch started. | libmodel.Watch | **[USED]** |
| `VMEventHandler.Created()` | VM created. | libmodel.Watch | **[USED]** |
| `VMEventHandler.Updated()` | VM updated. | libmodel.Watch | **[USED]** |
| `VMEventHandler.Error()` | Report errors. | libmodel.Watch | **[USED]** |
| `VMEventHandler.End()` | Watch ended. | libmodel.Watch | **[USED]** |

---

## 2. Provider Model

### model/doc.go

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `All()` | Returns model types. | `provider/model/doc.go:40` | **[USED]** |

### model/model.go

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `(m *Base) Pk()`, `String()`, `Labels()`, `GetName()` | Model interface. | libmodel | **[USED]** |
| `(m *VM) Validated()` | Revision validated. | `watch.go:95`, `:115` | **[USED]** |

### model/tree.go

| Symbol | Description | Callers | Status |
|--------|-------------|---------|--------|
| `VmKind` | Kind for VM. | `web/hyperv/tree.go` | **[USED]** |
| `NetKind`, `DiskKind`, `StorageKind` | Kind strings. | No hyperv callers | **[MIMICKED]** |

---

## 3. Provider Web

### base.go

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `Handler.Prepare()` | Validates provider, parity. | All handlers | **[USED]** |
| `Handler.ListOptions()` | Builds list options. | VM, Network, Storage | **[USED]** |
| `Resource.With()` | Populates resource. | All resources | **[USED]** |

### doc.go

| Symbol | Description | Callers | Status |
|--------|-------------|---------|--------|
| `Handlers()` | Registers handlers. | `provider/web/doc.go:46` | **[USED]** |

### network.go, storage.go, provider.go, tree.go, vm.go, workload.go

All handlers (AddRoutes, List, Get, watch, filter) and resource methods (With, Link, Content) are **[USED]** by REST API and internal callers.

### types.go

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `Resolver.Path()` | Builds URL path. | `base/client.go` | **[USED]** |
| `NewFinder()` | Creates finder. | `provider/web/client.go:114` | **[USED]** |
| `Finder.ByRef()`, `VM()`, `Workload()`, `Network()`, `Storage()` | Find by ref. | ProviderClient, validation, migration | **[USED]** |
| `Finder.Host()` | Always error for HyperV. | `host/validation.go` | **[USED]** |

---

## 4. Provider Validation

### validation.go (HyperV-related)

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `isValidSMBPath()` | Validates SMB URL. | `validateSecret()` | **[USED]** |
| `validateSMBCSI()` | Validates SMB CSI driver. | `validate()` | **[USED]** |

---

## 5. Dead Code

- **collector.go:** `HyperVCredentials()`, `SMBCredentials()`, `SMBPath()`, `SMBUrl()` — **[DEAD]** — never called. The hyperv-provider-server (separate binary) reads credentials from env; the MTV controller collector does not use these. Consider removing or documenting for future use (e.g. migration builder that needs SMB access).

---

## 6. Mimicked / Interface Compliance

| Item | Notes |
|------|-------|
| `Collector.Name()`, `Reset()`, `Version()`, `Follow()` | Required by libcontainer.Collector interface; some are NO-OP or unimplemented for HyperV. |
| `Finder.Host()` | Returns `ResourceNotResolvedError` — HyperV has no hosts; host validation fails for HyperV Host CRs (expected). |
| `Workload.List()` | Empty implementation; no list route registered. Mirrors other providers. |
| `Workload.Expand()` | Effectively a no-op (re-fetches VM, does not populate extra fields). HyperV has no host/cluster hierarchy to expand. |

---

## 7. External Integration

| Component | Usage |
|-----------|-------|
| **Plan handler** | `plan/handler/hyperv` — watches `hyperv.VM`, triggers plan reconcile. |
| **Plan adapter** | `plan/adapter/hyperv` — validator, builder, client use `hyperv.VM`, `hyperv.Network`, etc. |
| **Network map handler** | `map/network/handler/hyperv` — watches `hyperv.Network`. |
| **Storage map handler** | `map/storage/handler/hyperv` — no-op Watch (single SMB share). |
| **Host handler** | `host/handler/hyperv` — no-op Watch (single host). |
| **Provider web client** | `provider/web/client.go` — `hyperv.NewFinder()`, `hyperv.Resolver` for HyperV. |
| **Inventory VM/Network/Storage/Workload** | Used by plan validation, map validation, migration, hooks. |

---

## 8. Call Graph (Key Flows)

**Collector lifecycle:**
```
container.Build() → hyperv.New()
container.Add/Replace() → collector.Start()
container.Replace() (old) → collector.Shutdown()
```

**REST API:**
```
provider/web/doc.go → hyperv.Handlers(container)
Handlers → ProviderHandler, VMHandler, NetworkHandler, StorageHandler, TreeHandler, WorkloadHandler
Each handler → h.Prepare() → h.Collector.HasParity(), h.Collector.DB()
```

**Inventory lookup:**
```
web.NewClient(provider) → hyperv.NewFinder() when provider is HyperV
ProviderClient.VM(ref) → Finder.VM(ref) → ByRef(vm, ref)
ProviderClient.Network(ref) → Finder.Network(ref)
ProviderClient.Storage(ref) → Finder.Storage(ref)
ProviderClient.Workload(ref) → Finder.Workload(ref)
ProviderClient.Host(ref) → Finder.Host(ref) [always error for HyperV]
```

**Validation:**
```
validation.validate() → validateSMBCSI() for HyperV
validation.validateSecret() → isValidSMBPath(smbUrl) for HyperV
```

---

*Generated from codebase analysis.*
