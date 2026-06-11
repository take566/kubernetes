# External load balancer for kubeadm API (TCP 6443)

Use this **Option A** when you need a stable `controlPlaneEndpoint` before `kubeadm init` (HA control plane or fixed VIP on bare metal).

MetalLB (**Option B**, `kubeadm/addons/metallb/`) assigns IPs to Kubernetes `Service` type `LoadBalancer` **after** the cluster exists. It does not replace an external VIP for the API server during bootstrap unless you design a separate front-end.

## Prerequisites

- Two or more Linux hosts for keepalived + HAProxy (or combine on control-plane nodes)
- A free virtual IP (VIP) on the same L2 segment as control-plane nodes
- DNS record (e.g. `cp.example.com`) pointing to the VIP

Set before init:

```bash
export CONTROL_PLANE_IP=192.168.1.10      # first control-plane node
export CONTROL_PLANE_DNS=cp.example.com   # VIP DNS name
./kubeadm/scripts/00-configure-lb.sh --check-api
```

## Minimal keepalived + HAProxy (TCP 6443)

### HAProxy (`/etc/haproxy/haproxy.cfg`)

```cfg
global
    log /dev/log local0
    maxconn 4096

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 5s
    timeout client  1h
    timeout server  1h

frontend k8s-api
    bind *:6443
    default_backend k8s-api-back

backend k8s-api-back
    balance roundrobin
    option tcp-check
    server cp1 192.168.1.10:6443 check
    server cp2 192.168.1.11:6443 check
    server cp3 192.168.1.12:6443 check
```

```bash
sudo apt-get install -y haproxy
sudo systemctl enable --now haproxy
```

### keepalived (`/etc/keepalived/keepalived.conf`)

```conf
vrrp_script chk_haproxy {
    script "pidof haproxy"
    interval 2
    weight 2
}

vrrp_instance VI_1 {
    state MASTER                    # BACKUP on peer node
    interface eth0                  # your LAN interface
    virtual_router_id 51
    priority 101                    # lower on BACKUP (e.g. 100)
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass your-secret-here
    }
    virtual_ipaddress {
        192.168.1.100/24 dev eth0   # VIP — map cp.example.com to this
    }
    track_script {
        chk_haproxy
    }
}
```

```bash
sudo apt-get install -y keepalived
sudo systemctl enable --now keepalived
```

## kubeadm alignment

1. Configure VIP/LB and DNS (`cp.example.com` → VIP).
2. Run `00-configure-lb.sh` and fix any checklist failures.
3. Set `controlPlaneEndpoint: "cp.example.com:6443"` in `kubeadm/kubeadm-config.yaml` (or use `03-init-control-plane.sh` env substitution).
4. `kubeadm init` on the first control plane; join additional control planes to the same endpoint.

## See also

- `kubeadm/scripts/00-configure-lb.sh` — endpoint validation
- `kubeadm/addons/metallb/` — in-cluster LoadBalancer IPs (post-init)
