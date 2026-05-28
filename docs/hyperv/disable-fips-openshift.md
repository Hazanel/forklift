# Disabling FIPS on an OpenShift Cluster (Post-Install)

OpenShift's MCO **blocks** changing `spec.fips` on a running cluster, but you can
override it at the kernel level via `kernelArguments`. The last `fips=` argument
on the kernel command line wins.

## Why this is needed

When FIPS mode is enabled, the kernel CIFS module cannot perform NTLM
authentication (which relies on HMAC-MD5). This causes SMB mounts to fail with:

```
Could not allocate HMAC-MD5
Error -2 during NTLMSSP authentication
```

This breaks the Forklift HyperV provider, which mounts SMB shares to access
Hyper-V VM disks.

## Disable FIPS on worker nodes

```bash
cat <<'EOF' | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-worker-disable-fips-kernel
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  kernelArguments:
    - fips=0
EOF
```

## Disable FIPS on master nodes (if needed)

```bash
cat <<'EOF' | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-master-disable-fips-kernel
  labels:
    machineconfiguration.openshift.io/role: master
spec:
  kernelArguments:
    - fips=0
EOF
```

## Monitor the rollout

```bash
# Watch MCP progress (nodes reboot one-by-one)
oc get mcp -w

# Check node status
oc get nodes

# Verify FIPS is actually off on a rebooted node
oc debug node/<node-name> -- chroot /host cat /proc/sys/crypto/fips_enabled
# Should return: 0
```

## Re-enable FIPS (revert)

```bash
oc delete machineconfig 99-worker-disable-fips-kernel
# (and 99-master-disable-fips-kernel if applied)
```

This triggers another rolling reboot, removing the `fips=0` override so the
original `fips=1` takes effect again.

## How it works

- The original installer sets `fips=1` in the kernel command line via grub.
- `MachineConfig.spec.kernelArguments` **appends** additional args to the
  command line.
- The kernel processes `fips=` left-to-right; the **last** value wins.
- So `fips=1 ... fips=0` results in FIPS disabled.
- The MCO only guards `spec.fips` (the install-time flag), not arbitrary
  `kernelArguments`.

## Important notes

- Each node reboots during the rollout (~5–8 min per node).
- Workloads are drained before reboot (no downtime if you have enough nodes).
- `kernelArguments` is a documented MCO field.
- Disabling FIPS on a FIPS-installed cluster may violate compliance
  requirements — only do this in test/dev environments or when compliance is
  not required.
