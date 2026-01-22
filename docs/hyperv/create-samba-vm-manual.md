# Manual VM Creation for Samba Server

## Step 1: Create VM via Web UI

1. Go to: https://rhos-d.infra.prod.upshift.rdu2.redhat.com/dashboard/project/
2. Navigate to: **Compute → Instances**
3. Click: **Launch Instance**

### Configuration:

**Details Tab:**
- Instance Name: `hyperv-samba-server`

**Source Tab:**
- Select Boot Source: **Image**
- Create New Volume: **No** (or Yes if you need persistent storage)
- Image Name: Select **RHEL 9** or **Fedora** or **CentOS Stream 9**

**Flavor Tab:**
- Select: **m1.small** (or m1.medium if available)

**Networks Tab:**
- Select a network that is accessible from your OpenShift cluster
- **IMPORTANT:** Note the network CIDR for security group rules

**Security Groups Tab:**
- Create new or select existing group with:
  - **SSH (22)** - from your IP or 0.0.0.0/0
  - **SMB (445)** - from OpenShift cluster CIDR
  - **SMB (139)** - from OpenShift cluster CIDR
  
  If creating new rules:
  - Click "Manage Security Group Rules"
  - Add Rule → Custom TCP Rule
    - Port: 445, CIDR: OpenShift-cluster-CIDR
  - Add Rule → Custom TCP Rule
    - Port: 139, CIDR: OpenShift-cluster-CIDR

**Key Pair Tab:**
- Select your SSH key pair (or create one)

4. Click **Launch Instance**
5. Wait for Status to become **Active**
6. Note the **IP Address** assigned to the VM

---

## Step 2: Setup Samba Commands

Once you have the VM IP, run:

```bash
# SSH to the VM (replace VM_IP with actual IP)
# Username is usually: cloud-user, fedora, or centos
ssh cloud-user@VM_IP

# Install Samba
sudo dnf install -y samba samba-client

# Create directory
sudo mkdir -p /srv/hyperv-vms
sudo chmod 755 /srv/hyperv-vms

# Add Samba configuration
sudo tee -a /etc/samba/smb.conf > /dev/null <<'EOF'

[hyperv-vms]
    path = /srv/hyperv-vms
    browseable = yes
    read only = yes
    guest ok = yes
    public = yes
    force user = nobody
    force group = nobody
    create mask = 0755
    directory mask = 0755
EOF

# Start Samba
sudo systemctl start smb
sudo systemctl enable smb
sudo systemctl status smb

# Configure firewall
sudo firewall-cmd --permanent --add-service=samba
sudo firewall-cmd --reload

echo "✅ Samba setup complete!"
echo "SMB Share: //VM_IP/hyperv-vms"
```

---

## Step 3: Test SMB Access

From your local machine:
```bash
smbclient -L //VM_IP/hyperv-vms -N
```

---

## Step 4: Create HyperV Provider in OpenShift

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: hyperv-openstack-creds
  namespace: openshift-mtv
type: Opaque
stringData:
  username: "guest"
  password: ""
---
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: hyperv-openstack
  namespace: openshift-mtv
spec:
  type: hyperv
  url: "smb://VM_IP/hyperv-vms"
  secret:
    name: hyperv-openstack-creds
    namespace: openshift-mtv
EOF
```

---

## Next Steps

Once you create the VM and give me the IP, I'll help:
1. Run the Samba setup commands
2. Test connectivity from OpenShift
3. Create the HyperV provider
4. Verify it works end-to-end

---

**Create the VM now and let me know the IP address!** 🚀
