# Changelog
## proxmox-flatcar

---
  ---
  ---
---

## v1.0.0 (10/11/2021)
---
### Enhancements:

- **First version**

- **Supported OS:**
  - Flatcar Stable 2983.2.0
  - Proxmox VE <= 6.2
  - RHEL and CentOS 8

### Fixed :

- N/A

---

### Known Issues :

- Cloned VM from template don't update it's ignition file when modifying CloudInit config in Proxmox VE GUI
- If not shared storage is used to deploy template VM you can only deploy VM on same host as template VM (can't migrate)
- Only IPv4 is supported

---

### Future features

- Ansible role to deploy kubernetes clusters using proxmoxer and kubespray --> target version: unknown
