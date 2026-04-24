# Hyper-V iSCSI Migration Flow

## Sequence Diagram

```mermaid
sequenceDiagram
    autonumber
    participant User as User / UI
    participant PlanCtrl as Plan Controller
    participant HVAdapter as Hyper-V Adapter
    participant HyperV as Hyper-V Host
    participant K8sAPI as Kubernetes API
    participant PopCtrl as Populator Controller
    participant PopPod as hyperv-populator Pod
    participant Node as OpenShift Worker Node
    participant V2V as virt-v2v Pod

    rect rgb(59, 130, 246, 0.1)
    Note over User,K8sAPI: Phase 1 — Setup & Validation
    User->>K8sAPI: Create Plan CR (hyperv, iscsi mode)
    PlanCtrl->>HyperV: WinRM: CheckIscsiReadiness<br/>(iSCSI Target feature + port 3260)
    HyperV-->>PlanCtrl: Ready ✓
    PlanCtrl->>K8sAPI: Update Plan status (Ready)
    User->>K8sAPI: Create Migration CR
    end

    rect rgb(245, 158, 11, 0.1)
    Note over PlanCtrl,HyperV: Phase 2 — Pre-Transfer (WinRM)
    PlanCtrl->>HyperV: WinRM: Power off source VM
    HyperV-->>PlanCtrl: VM powered off

    PlanCtrl->>HVAdapter: PreTransferActions()
    HVAdapter->>HyperV: WinRM: CreateTarget(targetName, initiatorIQN)
    Note right of HyperV: Creates iSCSI target<br/>iqn.1991-05.com.microsoft:hostname-forklift-vmid-target<br/>Listening on TCP 3260
    HyperV-->>HVAdapter: Target IQN + Portal

    HVAdapter->>HyperV: WinRM: SetupDiskForMigration()<br/>per disk
    Note right of HyperV: 1. Create differencing VHDX<br/>2. Create iSCSI virtual disk<br/>3. Map LUN to target<br/>4. Set ACL for initiator IQN
    HyperV-->>HVAdapter: LUN ID

    HVAdapter->>K8sAPI: Patch Migration annotations<br/>iscsi-iqn.{vmID} = targetIQN
    end

    rect rgb(16, 185, 129, 0.1)
    Note over HVAdapter,PopPod: Phase 3 — Disk Transfer
    HVAdapter->>K8sAPI: Create HyperVVolumePopulator CR<br/>(targetIQN, portal, initiatorIQN, lunID, secretName)
    HVAdapter->>K8sAPI: Create PVC<br/>(dataSourceRef → HyperVVolumePopulator)

    PopCtrl->>K8sAPI: Watch PVC → detect pending population
    PopCtrl->>K8sAPI: Create prime-PVC + populator Pod<br/>(privileged, hostNetwork, hostPID)

    Note over PopPod,Node: Populator Pod starts on worker node

    PopPod->>Node: Use host's iSCSI initiator (iscsid)
    Node-->>PopPod: iscsid available ✓

    PopPod->>Node: Create per-session iSCSI interface<br/>(binds forklift initiator IQN)
    Note right of PopPod: Dedicated interface ensures<br/>ACL match without changing<br/>node's global iSCSI config

    PopPod->>Node: Register target address in<br/>local iSCSI initiator database
    Note right of PopPod: Tells initiator where<br/>the target is — avoids<br/>unreliable SendTargets discovery

    PopPod->>HyperV: iscsiadm --login<br/>TCP 3260
    HyperV-->>PopPod: iSCSI session established

    PopPod->>Node: Poll /host-dev/disk/by-path/<br/>ip-{host}-iscsi-{iqn}-lun-{N}
    Node-->>PopPod: /dev/sda (block device)

    PopPod->>Node: Read /sys/class/block/sda/size
    Node-->>PopPod: Device size in sectors

    PopPod->>PopPod: dd if=/dev/sda of=/mnt/disk.img<br/>bs=8M iflag=direct oflag=direct
    Note right of PopPod: Direct I/O bypasses Linux page cache<br/>to avoid memory pressure on the node.<br/>Speed depends on network to Hyper-V host.

    loop Every progress update
        PopPod->>PopPod: Parse dd stderr → update<br/>Prometheus gauge progress{ownerUID}
        PopCtrl->>PopPod: GET https://{nodeIP}:8443/metrics
        PopPod-->>PopCtrl: progress{ownerUID="..."} 42.5
        PopCtrl->>K8sAPI: UpdateStatus on<br/>HyperVVolumePopulator CR
        PlanCtrl->>K8sAPI: Read populator status →<br/>update Plan pipeline progress
    end

    PopPod->>PopPod: Verify first 1KB non-zero<br/>Check MBR/GPT signature
    end

    rect rgb(239, 68, 68, 0.1)
    Note over PopPod,HyperV: Phase 4 — Cleanup
    PopPod->>Node: iscsiadm --logout
    PopPod->>Node: iscsiadm -m node --op=delete
    PopPod->>Node: iscsiadm -m iface --op=delete

    PopCtrl->>K8sAPI: Bind prime-PVC → rebind to original PVC
    Note over PopCtrl: PVC now contains<br/>the full disk image

    PlanCtrl->>HVAdapter: Finalize()
    HVAdapter->>HyperV: WinRM: CleanupDiffDisks()
    HVAdapter->>HyperV: WinRM: RemoveTarget()
    end

    rect rgb(139, 92, 246, 0.1)
    Note over PlanCtrl,V2V: Phase 5 — Guest Conversion
    PlanCtrl->>K8sAPI: Create virt-v2v Pod<br/>(V2V_inPlace=1, V2V_source=hyperv)
    V2V->>V2V: virt-v2v-in-place -i disk<br/>Install VirtIO drivers<br/>Fix bootloader & registry
    V2V-->>PlanCtrl: Pod Succeeded
    end

    rect rgb(6, 182, 212, 0.1)
    Note over PlanCtrl,K8sAPI: Phase 6 — VM Creation
    PlanCtrl->>K8sAPI: Create VirtualMachine CR<br/>(KubeVirt) with PVCs as disks
    PlanCtrl->>K8sAPI: Patch PVC ownerReferences → VM
    PlanCtrl->>K8sAPI: Update Migration status: Succeeded
    Note over User: VM running on<br/>OpenShift Virtualization ✓
    end
```

## Component Diagram

```mermaid
graph TB
    subgraph HV["Hyper-V Host"]
        direction TB
        WinRM["WinRM / PowerShell"]
        subgraph Storage["Disk Storage"]
            OrigVHDX["Original VM Disk (.vhdx)"]
            DiffVHDX["Differencing VHDX<br/>(read-only snapshot)"]
        end
        iSCSITarget["iSCSI Target Server<br/>TCP 3260"]

        DiffVHDX -.->|"parent"| OrigVHDX
        WinRM -->|"creates"| iSCSITarget
        WinRM -->|"creates"| DiffVHDX
        iSCSITarget ---|"exposes"| DiffVHDX
    end

    subgraph OCP["OpenShift Cluster"]
        direction TB

        subgraph CP["Control Plane"]
            API["Kubernetes API Server"]
            PlanCtrl["Plan Controller<br/>(forklift-controller)"]
            PopCtrl["Populator Controller<br/>(volume-populator-controller)"]
        end

        subgraph WN["Worker Node"]
            direction TB

            subgraph Transfer["Phase 3 — Disk Transfer"]
                PopPod["hyperv-populator Pod<br/>(privileged, hostNetwork)"]
                HostISCSI["Host iSCSI Initiator<br/>(iscsid on node)"]
                BlockDev["/dev/sdX<br/>(iSCSI block device)"]
            end

            subgraph Convert["Phase 5 — Guest Conversion"]
                V2VPod["virt-v2v-in-place Pod"]
            end

            PVC["PVC — target disk"]
            VM["KubeVirt VM"]
        end
    end

    %% Phase 1-2: Setup via WinRM
    PlanCtrl -->|"1. WinRM: Create target<br/>+ diff VHDX + ACL"| WinRM

    %% Phase 3: Populator flow
    PlanCtrl -->|"2. Create HyperVVolumePopulator<br/>CR + PVC"| API
    PopCtrl -->|"3. Watch PVC,<br/>spawn populator Pod"| API

    PopPod -->|"4. Use host iSCSI<br/>initiator"| HostISCSI
    HostISCSI ==>|"5. iSCSI Login<br/>TCP 3260"| iSCSITarget
    HostISCSI -->|"attaches"| BlockDev
    PopPod -->|"6. dd copy<br/>(direct I/O)"| BlockDev
    PopPod -->|"writes to"| PVC

    %% Progress reporting
    PopPod -.->|"7. Prometheus<br/>HTTPS :8443"| PopCtrl

    %% Phase 5: Conversion
    V2VPod -->|"8. In-place convert<br/>(VirtIO, bootloader)"| PVC

    %% Phase 6: VM
    VM -->|"9. Boots from"| PVC

    %% Phase 4: Cleanup
    PlanCtrl -->|"10. WinRM: Remove<br/>target + diff disks"| WinRM

    %% Styling
    style PopPod fill:#10b981,color:#fff
    style iSCSITarget fill:#f59e0b,color:#fff
    style VM fill:#06b6d4,color:#fff
    style PVC fill:#3b82f6,color:#fff
    style HostISCSI fill:#6366f1,color:#fff
    style V2VPod fill:#8b5cf6,color:#fff
    style DiffVHDX fill:#f59e0b,color:#fff,stroke:#f59e0b

    linkStyle 4 stroke:#10b981,stroke-width:3px
    linkStyle 5 stroke:#10b981,stroke-width:3px
```

## Network Calls Summary

| Protocol | From | To | Purpose |
|----------|------|----|---------|
| WinRM/HTTPS | Plan Controller | Hyper-V Host | Target setup, teardown, readiness checks |
| iSCSI (TCP 3260) | Worker Node (hostNetwork) | Hyper-V Portal | Block-level disk data transfer |
| HTTPS :8443 | Populator Controller | Worker Node PodIP | Prometheus metrics scrape (progress) |
| Kubernetes API | All controllers | kube-apiserver | CR CRUD, PVC binding, Pod lifecycle |
