# Hyper-V Provider Server Code Review

**Commit:** 55794aaaa  
**Branch:** hyperV_libvirt  
**Reviewed:** February 10, 2025

---

## 1. cmd/hyperv-provider-server/collector/collector.go

### Exported Functions

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `NewCollector(s *settings.ProviderSettings) *Collector` | Creates a new HyperV collector with WinRM driver and context. | `main.go:53` | **[USED]** |
| `(*Collector).Start()` | Starts the collector goroutine: connects, discovers SMB prefix, runs initial refresh, then periodic refresh loop. | `main.go:54` (goroutine) | **[USED]** |
| `(*Collector).Stop()` | Cancels the collector context to stop the refresh loop. | *None* | **[DEAD]** |
| `(*Collector).GetVMs() []VM` | Returns cached VM inventory (thread-safe). | `handler/handler.go:35` | **[USED]** |
| `(*Collector).GetNetworks() []Network` | Returns cached network inventory (thread-safe). | `handler/handler.go:47` | **[USED]** |
| `(*Collector).GetStorages() []Storage` | Returns cached storage inventory (thread-safe). | `handler/handler.go:59` | **[USED]** |
| `(*Collector).GetDisks() []Disk` | Returns all disks from all VMs (thread-safe). | `handler/handler.go:71` | **[USED]** |
| `(*Collector).HasParity() bool` | Returns whether initial sync has completed. | *None* (not exposed via HTTP; MTV controller uses its own container collector) | **[DEAD]** |
| `(*Collector).TestConnection() bool` | Performs live WinRM connectivity check. | `handler/handler.go:84` | **[USED]** |

### Internal (unexported) Functions

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `(*Collector).refresh()` | Refreshes inventory: networks, VMs, storages; preserves KVP data when VM is off. | `Start()` (direct + ticker) | **[USED]** |
| `(*Collector).loadNetworks() ([]Network, error)` | Loads networks via `driver.ListAllNetworks()`. | `refresh()` | **[USED]** |
| `(*Collector).extractStorages() []Storage` | Extracts storage from SMB URL and Windows path. | `refresh()` | **[USED]** |
| `(*Collector).getStorageCapacity(windowsPath string) (int64, int64)` | Queries volume capacity via PowerShell. | `extractStorages()` | **[USED]** |
| `(*Collector).loadVMs(networks, smbWindowsPrefix) ([]VM, error)` | Loads VMs via `driver.ListAllDomains()`, processes each. | `refresh()` | **[USED]** |
| `(*Collector).getVMFromDomain(domain, networks, smbWindowsPrefix) (*VM, error)` | Converts a domain to VM struct (state, disks, NICs, KVP, concerns). | `loadVMs()` | **[USED]** |
| `(*Collector).extractDisks(domain, smbWindowsPrefix) []Disk` | Extracts disk info from domain. | `getVMFromDomain()` | **[USED]** |
| `(*Collector).extractNICs(domain, networks) []NIC` | Extracts NIC info from domain. | `getVMFromDomain()` | **[USED]** |
| `formatMAC(mac string) string` | Normalizes MAC to XX:XX:XX:XX:XX:XX. | `extractNICs()` | **[USED]** |
| `(*Collector).collectGuestOS(vmName string) (string, error)` | Gets guest OS via KVP. | `getVMFromDomain()` | **[USED]** |
| `(*Collector).collectSecurityInfo(vmName string) (*securityInfo, error)` | Gets TPM/SecureBoot for Gen2 VMs. | `getVMFromDomain()` | **[USED]** |
| `(*Collector).collectHasCheckpoint(vmName string) (bool, error)` | Checks for VM snapshots. | `getVMFromDomain()` | **[USED]** |
| `(*Collector).collectGuestNetworkConfig(vmName, nics) ([]GuestNetwork, error)` | Gets IP config via KVP Exchange. | `getVMFromDomain()` | **[USED]** |
| `filterDNSByFamily(dns []string, ipv4 bool) []string` | Filters DNS by IP family. | `collectGuestNetworkConfig()` | **[USED]** |
| `findNICDeviceIndex(mac string, nics []NIC) int` | Matches MAC to NIC device index. | `collectGuestNetworkConfig()` | **[USED]** |
| `subnetToPrefixLength(subnet string) int32` | Converts IPv4 subnet to prefix length. | `collectGuestNetworkConfig()` | **[USED]** |
| `parseIPv6PrefixLength(subnet string) int32` | Parses IPv6 prefix length. | `collectGuestNetworkConfig()` | **[USED]** |
| `(*Collector).mapWindowsPathToSMB(windowsPath, smbWindowsPrefix) string` | Maps Windows path to SMB mount path. | `extractDisks()` | **[USED]** |
| `(*Collector).getDiskCapacity(windowsPath string) int64` | Gets VHD size via PowerShell. | `extractDisks()` | **[USED]** |
| `(*Collector).getDiskRCTEnabled(windowsPath string) bool` | Checks RCT for warm migration. | `extractDisks()` | **[USED]** |
| `(*Collector).discoverSMBWindowsPrefix() error` | Discovers SMB share path via Get-SmbShare. | `Start()` | **[USED]** |
| `resolveNetworkUUID(name string, networks []Network) string` | Resolves switch name to UUID. | `extractNICs()` | **[USED]** |
| `(*Collector).validateDisksExistOnSMB(disks []Disk) []Concern` | Checks disk files exist on SMB mount. | `getVMFromDomain()` | **[USED]** |
| `mapPowerState(state DomainState) string` | Maps domain state to "On"/"Off"/etc. | `getVMFromDomain()` | **[USED]** |
| `extractHostFromURL(addr string) string` | Extracts host from HyperV URL. | `NewCollector()` | **[USED]** |
| `extractShareName(smbUrl string) string` | Extracts share name from SMB URL. | `extractStorages()`, `discoverSMBWindowsPrefix()` | **[USED]** |

### Summary
- **Dead code:** `Stop()`, `HasParity()` — never called. `Stop()` especially matters for graceful shutdown.
- **Recommendation:** Wire `Stop()` into signal handling (SIGTERM) in `main.go` for graceful shutdown. Consider exposing `HasParity` via HTTP or removing if not needed.

---

## 2. cmd/hyperv-provider-server/driver/driver.go

### Types and Interfaces (no functions)

| Item | Description | Status |
|------|-------------|--------|
| `HyperVDriver` interface | `Connect`, `Close`, `IsAlive`, `ListAllDomains`, `LookupDomainByName`, `LookupDomainByUUIDString`, `ListAllNetworks`, `LookupNetworkByUUIDString`, `ExecuteCommand` | Interface only |
| `Domain` interface | `GetName`, `GetUUIDString`, `GetState`, `GetInfo`, `GetGeneration`, `GetDisks`, `GetNICs`, `Shutdown`, `Free` | Interface only |
| `Network` interface | `GetName`, `GetUUIDString`, `GetSwitchType`, `Free` | Interface only |
| `GuestNetworkInfo` struct | Holds MAC, DHCP, IPs, prefix lengths, gateways, DNS. | **[MIMICKED]** — Defined but never used. Collector uses internal `guestNetConfig` from KVP JSON. |

### Summary
- **Mimicked:** `GuestNetworkInfo` appears copied from libvirt/oVirt patterns but is unused; collector uses inline KVP structs.

---

## 3. cmd/hyperv-provider-server/driver/winrm.go

### Exported Functions

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `NewWinRMDriver(...) *WinRMDriver` | Creates WinRM driver with host, creds, TLS settings. | `collector/collector.go:140` | **[USED]** |
| `(*WinRMDriver).Connect() error` | Establishes WinRM HTTPS connection. | `collector.Start()`, `collector.refresh()` | **[USED]** |
| `(*WinRMDriver).Close() error` | Clears client reference. | `collector.Start()` (on ctx.Done()) | **[USED]** |
| `(*WinRMDriver).IsAlive() (bool, error)` | Runs `echo ok` to test connectivity. | `collector.Start()`, `refresh()`, `TestConnection()` | **[USED]** |
| `(*WinRMDriver).ExecuteCommand(command string) (string, error)` | Executes PowerShell command with default timeout. | All collector/driver call sites | **[USED]** |
| `(*WinRMDriver).ExecuteCommandWithTimeout(command, timeout) (string, error)` | Executes with custom timeout. | `ExecuteCommand()` only | **[USED]** |
| `(*WinRMDriver).ListAllDomains() ([]Domain, error)` | Lists all VMs via Get-VM. | `collector.loadVMs()` | **[USED]** |
| `(*WinRMDriver).LookupDomainByName(name string) (Domain, error)` | Gets single VM by name. | *None* | **[DEAD]** |
| `(*WinRMDriver).LookupDomainByUUIDString(uuid string) (Domain, error)` | Gets single VM by UUID. | *None* | **[DEAD]** |
| `(*WinRMDriver).ListAllNetworks() ([]Network, error)` | Lists all virtual switches. | `collector.loadNetworks()` | **[USED]** |
| `(*WinRMDriver).LookupNetworkByUUIDString(uuid string) (Network, error)` | Gets network by UUID. | *None* | **[DEAD]** |

### WinRMDomain (implements Domain)

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `GetName()`, `GetUUIDString()`, `GetState()`, `GetInfo()`, `GetGeneration()` | Return VM metadata. | `collector.getVMFromDomain()` | **[USED]** |
| `GetDisks()`, `GetNICs()` | Return disk/NIC info. | `collector.extractDisks()`, `extractNICs()` | **[USED]** |
| `(*WinRMDomain).Shutdown(ctx) error` | Stops VM via Stop-VM. | *None* (Domain Shutdown not called by collector) | **[MIMICKED]** |
| `(*WinRMDomain).Free() error` | No-op for WinRM. | `collector.loadVMs()` (on each domain) | **[USED]** |

### WinRMNetwork (implements Network)

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `GetName()`, `GetUUIDString()`, `GetSwitchType()`, `Free()` | Network metadata. | `collector.loadNetworks()` | **[USED]** |

### Internal Helpers

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `utf16LEEncode(s string) []byte` | Encodes string for PowerShell -EncodedCommand. | `ExecuteCommandWithTimeout()` | **[USED]** |

### Summary
- **Dead code:** `LookupDomainByName`, `LookupDomainByUUIDString`, `LookupNetworkByUUIDString` — interface methods implemented but never called. Collector uses `ListAllDomains` / `ListAllNetworks` only.
- **Mimicked:** `Domain.Shutdown()` — part of interface (likely from libvirt pattern) but never invoked; plan adapter uses its own WinRM client for PowerOff.

---

## 4. cmd/hyperv-provider-server/handler/handler.go

### Exported Functions

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `(*InventoryHandler).AddRoutes(e *gin.Engine)` | Registers /vms, /networks, /storages, /disks, /test_connection. | `main.go:63` | **[USED]** |
| `(*InventoryHandler).VMs(ctx *gin.Context)` | Returns cached VMs as JSON. | Gin route `/vms` | **[USED]** |
| `(*InventoryHandler).Networks(ctx *gin.Context)` | Returns cached networks as JSON. | Gin route `/networks` | **[USED]** |
| `(*InventoryHandler).Storages(ctx *gin.Context)` | Returns cached storages as JSON. | Gin route `/storages` | **[USED]** |
| `(*InventoryHandler).Disks(ctx *gin.Context)` | Returns cached disks as JSON. | Gin route `/disks` | **[USED]** |
| `(*InventoryHandler).TestConnection(ctx *gin.Context)` | Returns connection status. | Gin route `/test_connection` | **[USED]** |

### Summary
- All handler functions are used. No dead code.

---

## 5. cmd/hyperv-provider-server/main.go

### Exported / Package-Level

| Item | Description | Status |
|------|-------------|--------|
| `Settings` | Global `ProviderSettings` with `DefaultCatalogPath: "/hyperv"`. | **[USED]** |
| `main()` | Loads settings, creates collector, starts HTTP server. | Entry point | **[USED]** |

### Flow
- `Settings.Load()` → `Settings.LoadHyperV()` → `collector.NewCollector()` → `hvCollector.Start()` (goroutine) → `inventoryHandler.AddRoutes()` → `router.Run()`.
- **Note:** No signal handling; `collector.Stop()` is never called on shutdown.

---

## 6. cmd/hyperv-provider-server/powershell/scripts.go

### Exported Functions

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `BuildCommand(template string, args ...string) string` | Sanitizes args (quote escaping) and formats template. | `driver/winrm.go`, `collector/collector.go` (multiple) | **[USED]** |

### Constants (PowerShell Scripts)

| Constant | Used By | Status |
|----------|---------|--------|
| `TestConnection` | `driver.IsAlive()` | **[USED]** |
| `ListAllVMs` | `driver.ListAllDomains()` | **[USED]** |
| `GetVMByName` | `driver.LookupDomainByName()` | **[DEAD]** (caller is dead) |
| `GetVMByID` | `driver.LookupDomainByUUIDString()` | **[DEAD]** (caller is dead) |
| `StopVM` | `driver` (WinRMDomain.Shutdown), `pkg/controller/plan/adapter/hyperv/client.go` (PowerOff) | **[USED]** |
| `ListAllSwitches` | `driver.ListAllNetworks()` | **[USED]** |
| `GetVMDisks` | `WinRMDomain.GetDisks()` | **[USED]** |
| `GetVMNICs` | `WinRMDomain.GetNICs()` | **[USED]** |
| `GetSMBSharePath` | `collector.discoverSMBWindowsPrefix()` | **[USED]** |
| `GetStorageCapacity` | `collector.getStorageCapacity()` | **[USED]** |
| `GetGuestNetworkConfig` | `collector.collectGuestNetworkConfig()` | **[USED]** |
| `GetGuestOS` | `collector.collectGuestOS()` | **[USED]** |
| `GetVMSecurityInfo` | `collector.collectSecurityInfo()` | **[USED]** |
| `GetVMHasCheckpoint` | `collector.collectHasCheckpoint()` | **[USED]** |
| `GetDiskCapacity` | `collector.getDiskCapacity()` | **[USED]** |
| `GetDiskRCTEnabled` | `collector.getDiskRCTEnabled()` | **[USED]** |

### Summary
- `GetVMByName` and `GetVMByID` are only used by dead `LookupDomainByName` / `LookupDomainByUUIDString`.
- **Bug in plan adapter:** `pkg/controller/plan/adapter/hyperv/client.go:110` uses `fmt.Sprintf(ps.StopVM, vm.Name)` instead of `ps.BuildCommand(ps.StopVM, vm.Name)`. VM names with quotes could break the script or introduce injection.

---

## 7. cmd/provider-common/settings/settings.go

### Exported Functions

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `(*ProviderSettings).Load() (err error)` | Loads common settings (auth, catalog path, port, provider). | `main.go:32` (hyperv), `ova-provider-server/main.go:32` | **[USED]** |
| `(*ProviderSettings).LoadHyperV() error` | Loads HyperV-specific settings (URL, creds, SMB, refresh, TLS). | `main.go:39` | **[USED]** |

### Internal

| Function | Description | Callers | Status |
|----------|-------------|---------|--------|
| `getEnvBool(name, def) bool` | Reads env var as bool. | `Load()` | **[USED]** |
| `getEnvInt(name, def) int` | Reads env var as int. | `Load()` | **[USED]** |

