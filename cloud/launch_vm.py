"""Create the always-on home lab VM on Oracle Cloud Always Free, retrying until capacity frees up.

Usage (from this folder):
    python launch_vm.py --check          # test the API key/config only, change nothing
    python launch_vm.py                  # network + VM, retries AD-1/2/3 until it gets 4 OCPU / 24 GB
    python launch_vm.py --fallback-after 30   # after 30 failed rounds, also try 2 OCPU / 12 GB in each AD

Idempotent: re-running reuses the network and stops early if the VM already exists.
Reads ~/.oci/config (DEFAULT profile). Writes vm-info.json + launch.log next to this script.
"""
import argparse
import json
import sys
import time
from datetime import datetime
from pathlib import Path

import oci

HERE = Path(__file__).resolve().parent
LOG = HERE / "launch.log"
INFO = HERE / "vm-info.json"
SSH_PUB = Path.home() / ".ssh" / "oracle_home_lab.pub"

VM_NAME = "home-lab-cloud"
VCN_NAME = "home-lab-vcn"
SUBNET_NAME = "home-lab-public"
IGW_NAME = "home-lab-igw"
SHAPE = "VM.Standard.A1.Flex"
BOOT_GB = 100
CAPACITY_HINTS = ("out of host capacity", "out of capacity")


def log(msg):
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S}  {msg}"
    print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def clients():
    config = oci.config.from_file()
    oci.config.validate_config(config)
    return (
        config,
        oci.identity.IdentityClient(config),
        oci.core.VirtualNetworkClient(config),
        oci.core.ComputeClient(config),
    )


def first(items, name):
    return next((i for i in items if i.display_name == name and i.lifecycle_state != "TERMINATED"), None)


def ensure_network(net, comp):
    """VCN + internet gateway + default route to it + public subnet (SSH 22 open via default security list)."""
    vcn = first(net.list_vcns(comp).data, VCN_NAME)
    if not vcn:
        log(f"Creating VCN {VCN_NAME}")
        vcn = net.create_vcn(oci.core.models.CreateVcnDetails(
            compartment_id=comp, display_name=VCN_NAME, cidr_blocks=["10.20.0.0/16"], dns_label="homelab",
        )).data
        vcn = oci.wait_until(net, net.get_vcn(vcn.id), "lifecycle_state", "AVAILABLE").data

    igw = first(net.list_internet_gateways(comp, vcn_id=vcn.id).data, IGW_NAME)
    if not igw:
        log("Creating internet gateway")
        igw = net.create_internet_gateway(oci.core.models.CreateInternetGatewayDetails(
            compartment_id=comp, vcn_id=vcn.id, display_name=IGW_NAME, is_enabled=True,
        )).data
        igw = oci.wait_until(net, net.get_internet_gateway(igw.id), "lifecycle_state", "AVAILABLE").data

    rt = net.get_route_table(vcn.default_route_table_id).data
    if not any(r.network_entity_id == igw.id for r in rt.route_rules):
        log("Adding default route 0.0.0.0/0 -> internet gateway")
        rules = rt.route_rules + [oci.core.models.RouteRule(
            destination="0.0.0.0/0", destination_type="CIDR_BLOCK", network_entity_id=igw.id)]
        net.update_route_table(rt.id, oci.core.models.UpdateRouteTableDetails(route_rules=rules))

    subnet = first(net.list_subnets(comp, vcn_id=vcn.id).data, SUBNET_NAME)
    if not subnet:
        log(f"Creating public subnet {SUBNET_NAME}")
        subnet = net.create_subnet(oci.core.models.CreateSubnetDetails(
            compartment_id=comp, vcn_id=vcn.id, display_name=SUBNET_NAME, cidr_block="10.20.1.0/24",
            dns_label="pub", prohibit_public_ip_on_vnic=False,
            route_table_id=vcn.default_route_table_id, security_list_ids=[vcn.default_security_list_id],
        )).data
        subnet = oci.wait_until(net, net.get_subnet(subnet.id), "lifecycle_state", "AVAILABLE").data
    return subnet


def ubuntu_image(compute, comp):
    images = compute.list_images(
        comp, operating_system="Canonical Ubuntu", operating_system_version="24.04", shape=SHAPE,
        sort_by="TIMECREATED", sort_order="DESC",
    ).data
    full = [i for i in images if "Minimal" not in i.display_name]
    if not (full or images):
        sys.exit("No Ubuntu 24.04 aarch64 image found for A1.")
    return (full or images)[0]


def public_ip(compute, net, comp, instance_id):
    for att in compute.list_vnic_attachments(comp, instance_id=instance_id).data:
        if att.lifecycle_state == "ATTACHED":
            return net.get_vnic(att.vnic_id).data.public_ip
    return None


def save_info(compute, net, comp, inst):
    inst = oci.wait_until(compute, compute.get_instance(inst.id), "lifecycle_state", "RUNNING",
                          max_wait_seconds=900).data
    ip = public_ip(compute, net, comp, inst.id)
    info = {"name": inst.display_name, "id": inst.id, "ad": inst.availability_domain,
            "ocpus": inst.shape_config.ocpus, "memory_gb": inst.shape_config.memory_in_gbs,
            "public_ip": ip, "ssh": f"ssh -i ~/.ssh/oracle_home_lab ubuntu@{ip}"}
    INFO.write_text(json.dumps(info, indent=2), encoding="utf-8")
    log(f"VM RUNNING: {json.dumps(info)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="only test the API config")
    ap.add_argument("--wait", type=int, default=180, help="seconds between retry rounds")
    ap.add_argument("--fallback-after", type=int, default=0, help="rounds before trying 2 OCPU / 12 GB (0 = never)")
    ap.add_argument("--max-rounds", type=int, default=0, help="stop after N rounds (0 = forever)")
    args = ap.parse_args()

    if sys.platform == "win32" and not args.check:
        # Block idle sleep while this process runs (ES_CONTINUOUS | ES_SYSTEM_REQUIRED); released on exit.
        import ctypes
        ctypes.windll.kernel32.SetThreadExecutionState(0x80000000 | 0x00000001)

    config, ident, net, compute = clients()
    comp = config["tenancy"]
    ads = [ad.name for ad in ident.list_availability_domains(comp).data]
    log(f"API OK. Region {config['region']}, ADs: {', '.join(ads)}")
    if args.check:
        return

    existing = first(compute.list_instances(comp).data, VM_NAME)
    if existing:
        log(f"{VM_NAME} already exists ({existing.lifecycle_state}).")
        save_info(compute, net, comp, existing)
        return

    subnet = ensure_network(net, comp)
    image = ubuntu_image(compute, comp)
    log(f"Image: {image.display_name}")
    ssh_key = SSH_PUB.read_text(encoding="utf-8").strip()

    rounds = 0
    while True:
        rounds += 1
        # After N rounds, each AD gets the full size first, then half size (smaller slots free up more often)
        sizes = [(4, 24), (2, 12)] if args.fallback_after and rounds > args.fallback_after else [(4, 24)]
        for ad, (ocpus, mem) in [(ad, s) for ad in ads for s in sizes]:
            try:
                inst = compute.launch_instance(oci.core.models.LaunchInstanceDetails(
                    compartment_id=comp, availability_domain=ad, display_name=VM_NAME, shape=SHAPE,
                    shape_config=oci.core.models.LaunchInstanceShapeConfigDetails(ocpus=ocpus, memory_in_gbs=mem),
                    source_details=oci.core.models.InstanceSourceViaImageDetails(
                        image_id=image.id, boot_volume_size_in_gbs=BOOT_GB),
                    create_vnic_details=oci.core.models.CreateVnicDetails(
                        subnet_id=subnet.id, assign_public_ip=True, hostname_label="home-lab-cloud"),
                    metadata={"ssh_authorized_keys": ssh_key},
                )).data
                log(f"Launched in {ad} with {ocpus} OCPU / {mem} GB. Waiting for RUNNING...")
                save_info(compute, net, comp, inst)
                return
            except oci.exceptions.ServiceError as e:
                text = (e.message or "").lower()
                if any(h in text for h in CAPACITY_HINTS):
                    log(f"Round {rounds} {ad.split(':')[-1]}: out of capacity ({ocpus}/{mem})")
                elif e.status == 429:
                    log("Rate limited; backing off 5 minutes")
                    time.sleep(300)
                else:
                    log(f"Stopping on unexpected error {e.status} {e.code}: {e.message}")
                    raise
            time.sleep(30)
        if args.max_rounds and rounds >= args.max_rounds:
            log("Max rounds reached; stopping.")
            return
        time.sleep(args.wait)


if __name__ == "__main__":
    # A new API key takes a few minutes to reach every Oracle endpoint (random 401s); main() is idempotent.
    # Network blips (timeouts, resets) just restart the loop; main() first checks whether a timed-out launch
    # actually created the VM, so nothing is ever launched twice.
    auth_failures = 0
    while True:
        try:
            main()
            break
        except oci.exceptions.ServiceError as e:
            if e.status != 401:
                log(f"Stopping on unexpected error {e.status} {e.code}: {e.message}")
                raise
            auth_failures += 1
            if auth_failures > 30:
                log("Error: still 401 after 30 minutes; check ~/.oci/config.")
                sys.exit(1)
            log(f"401 NotAuthenticated (key still propagating?), retry {auth_failures}/30 in 60 s")
            time.sleep(60)
        except (oci.exceptions.RequestException, oci.exceptions.ConnectTimeout, ConnectionError, OSError) as e:
            log(f"Network error ({type(e).__name__}); retrying in 60 s")
            time.sleep(60)
        except Exception as e:
            log(f"Error: crashed with {type(e).__name__}: {e}")
            raise
