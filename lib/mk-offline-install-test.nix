# mk-offline-install-test.nix
# ─────────────────────────────────────────────────────────────────────────────
# Boot a real installer ISO in a VM with NO network and run the real install
# script against a blank disk. The question it answers is the one an ISO cannot
# answer about itself: is the baked offline closure actually COMPLETE?
#
# Why a VM and not a build-time check. The closure gap this catches is not
# visible from the flake — it opens on the target box, because disko-install
# does not install the system that was baked. It re-evaluates the flake and
# installs `originalSystem.extendModules { … }` with `writeEfiBootEntries` from
# the firmware that booted the ISO, `boot.loader.grub.devices` from the disk the
# technician picked, and `disko.rootMountPoint` from disko-install's own
# --mount-point default. Every one of those is an input the ISO was baked
# WITHOUT. So the only honest test is the real ISO, real firmware, real disk.
#
# The failure it exists to catch is loud but badly signposted: offline-closure.nix
# ships runtime closures and deliberately not the build closure, so ONE divergent
# store path sends nix looking for a stdenv that is not there, then for bash, then
# for a bison tarball on gnu.org — and the install dies on a failed download three
# layers from the cause, with the disk already wiped.
#
# The VM has no `-netdev` at all: not a firewall rule, no NIC. A fetch fails
# instantly with "network is unreachable" instead of hanging for a timeout.
{
  lib,
  nixpkgs,
  system,
  # The installer-ISO nixosSystem under test — mk-installer-iso.nix's return
  # value, NOT its isoImage: the test extends it with the driver's backdoor.
  isoSystem,
  # Absolute path of the install script the ISO's boot service runs. The test
  # runs THIS, not a re-implementation of it, so the two cannot drift.
  installScript,
  # Environment for that script. A guided ISO is interactive by design; the
  # non-interactive contract (IH_NONINTERACTIVE / IH_DISK_DEVICE / IH_ANSWERS)
  # is what lets the test drive it. See scripts/guided-install.sh.
  scriptEnv ? { },
  # Answers to the project's guidedPrompts, keyed by dotted path. Written into
  # the VM and pointed at by IH_ANSWERS. Guided installs seed these as JSON for
  # the first-boot reconcile, so they never move the closure.
  answers ? null,
  # Derivation NAMES the target is allowed to build for itself, because the ISO
  # could not have baked them. Exactly one thing is ever in here: a guided ISO's
  # `disko` script, which has the technician's chosen device written inside it.
  # Anything else nix wants to build is a hole in the closure, and naming the
  # permitted set — rather than counting, or waving builds through — is what
  # makes a twenty-first rebuild visible on the day it appears.
  rebuildableOnTarget ? [ ],
  # Firmware the ISO is booted under. Both are baked by offline-closure.nix
  # (installVariants), and they install DIFFERENT systems — so which one is
  # tested is a real choice, not a detail.
  firmware ? "uefi", # "uefi" | "bios"
  # The disk disko-install is pointed at, as the guest sees it.
  diskDevice ? "/dev/vda",
  name ? "offline-install",
  diskSizeGiB ? 64,
  memorySizeMiB ? 8192,
  cores ? 4,
  # Wall-clock ceiling for the install itself. It copies the whole system
  # closure onto the target disk, which for a desktop is several GB.
  installTimeout ? 5400,
}:
let
  pkgs = nixpkgs.legacyPackages.${system};

  # ── The ISO under test, plus the driver's backdoor ─────────────────────────
  # extendModules rather than a separate build: everything that makes this the
  # artifact under test — the baked closure, isoImage.storeContents, the empty
  # substituter list, /etc/installer-* — is inherited unchanged. The additions
  # are the test driver's root shell on /dev/hvc0 and, crucially, NOT starting
  # the boot install service: it owns tty1 and would race the test for the disk.
  testIsoSystem = isoSystem.extendModules {
    modules = [
      "${nixpkgs}/nixos/modules/testing/test-instrumentation.nix"
      (
        { lib, ... }:
        {
          systemd.services.nixos-install.wantedBy = lib.mkForce [ ];
        }
      )
    ];
  };
  testIso = testIsoSystem.config.system.build.isoImage;

  answersJson = if answers == null then null else builtins.toJSON answers;

  # ── The emulated disk has to BE the device the manifest names ──────────────
  # An unattended ISO refuses to run when its baked diskDevice is not a block
  # device, and the device NAME is a property of the bus: virtio-blk enumerates
  # as /dev/vd*, SCSI as /dev/sd*, NVMe as /dev/nvme*. So the kind of disk qemu
  # attaches is decided by the path the project configured, not chosen here.
  diskBusArgs =
    if lib.hasPrefix "/dev/vd" diskDevice then
      [ ''"-device", "virtio-blk-pci,drive=target"'' ]
    else if lib.hasPrefix "/dev/sd" diskDevice then
      [
        ''"-device", "virtio-scsi-pci,id=scsi0"''
        ''"-device", "scsi-hd,bus=scsi0.0,drive=target"''
      ]
    else if lib.hasPrefix "/dev/nvme" diskDevice then
      [ ''"-device", "nvme,drive=target,serial=ih-offline-test"'' ]
    else
      throw ''
        mk-offline-install-test cannot emulate a disk that appears at "${diskDevice}".
        The device name follows from the bus qemu attaches (/dev/vd* virtio-blk,
        /dev/sd* SCSI, /dev/nvme* NVMe), so a project installing to some other
        path needs a case added here rather than a guess.
      '';

  envPrefix = lib.concatStringsSep " " (
    lib.mapAttrsToList (k: v: "${k}=${lib.escapeShellArg (toString v)}") scriptEnv
  );
in
pkgs.testers.runNixOSTest {
  inherit name;

  # No nodes: the only machine is hand-rolled below so it can boot the ISO from
  # an emulated CD-ROM rather than from a store-path system built for the VM.
  nodes = { };

  testScript = ''
    import glob
    import json
    import os
    import re
    import shutil
    import subprocess

    tmp_dir = os.environ.get("TMPDIR", "/tmp")

    iso = glob.glob("${testIso}/iso/*.iso")[0]

    # Sparse; qcow2 only ever occupies what the install writes.
    target_disk = os.path.join(tmp_dir, "${name}-target.qcow2")
    subprocess.run(
        [
            "${pkgs.qemu_test}/bin/qemu-img",
            "create", "-f", "qcow2", target_disk, "${toString diskSizeGiB}G",
        ],
        check=True,
        capture_output=True,
    )

    start_command = [
        "${pkgs.qemu_test}/bin/qemu-kvm",
        "-cpu", "max",
        "-smp", "${toString cores}",
        "-m", "${toString memorySizeMiB}",
        # No network interface at all, so a fetch fails immediately instead of
        # hanging on a timeout. This has to be said out loud: leaving -netdev off
        # is not enough, because qemu then helpfully supplies a DEFAULT user-mode
        # NIC — an e1000e with DHCP and a route to the host — and the test would
        # be measuring the sandbox's network policy rather than the ISO's closure.
        "-nic", "none",
        "-drive", f"file={iso},media=cdrom,format=raw,readonly=on",
        "-drive", f"file={target_disk},format=qcow2,id=target,if=none",
        ${lib.concatStringsSep ",\n        " diskBusArgs},
    ]

    ${lib.optionalString (firmware == "uefi") ''
      # A writable copy of the OVMF variable store: --write-efi-boot-entries runs
      # efibootmgr, which writes to NVRAM. With the read-only combined image it
      # would fail, and the EFI half of the install would go untested.
      ovmf_vars = os.path.join(tmp_dir, "${name}-OVMF_VARS.fd")
      shutil.copyfile("${pkgs.OVMF.variables}", ovmf_vars)
      os.chmod(ovmf_vars, 0o644)
      start_command += [
          "-machine", "q35",
          "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=${pkgs.OVMF.firmware}",
          "-drive", f"if=pflash,format=raw,unit=1,file={ovmf_vars}",
      ]
    ''}

    machine = create_machine(start_command=" ".join(start_command), name="installer")
    driver.machines_qemu.append(machine)

    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("the installer is genuinely offline"):
        # No NIC, so no route to anywhere. If this ever starts passing, every
        # result below becomes meaningless — a "successful" install would just
        # be one that quietly downloaded what the ISO forgot.
        machine.fail("ip route get 1.1.1.1")
        firmware_is_efi = machine.execute("test -d /sys/firmware/efi")[0] == 0
        expected_efi = ${if firmware == "uefi" then "True" else "False"}
        assert firmware_is_efi == expected_efi, (
            f"expected the ISO to boot under ${firmware} "
            f"(/sys/firmware/efi present: {expected_efi}), got {firmware_is_efi}"
        )

    manifest = json.loads(machine.succeed("cat /etc/installer-manifest.json"))
    host_attr = manifest.get("hostAttr", "install")
    disk_name = manifest.get("diskName", "main")
    # disko-install's own default when nothing pins it. The baked diskoScript is
    # built for disko's module default (/mnt), so a mismatch here IS the bug
    # class this test exists to find — mirror disko-install rather than assume.
    root_mount_point = manifest.get("rootMountPoint") or "/mnt/disko-install-root"
    efi_arg = "true" if firmware_is_efi else "false"

    with subtest("the offline closure covers this machine"):
        # Ask nix what installing HERE would build, before anything is written.
        # disko-install realises install-cli.nix with exactly these arguments;
        # every .drv nix names back is a path the ISO should have carried —
        # except the ones it demonstrably could not have, see rebuildableOnTarget.
        # (--dry-run with an empty substituter list prints no "will be fetched"
        # section, so a .drv anywhere in the output means "would be built".)
        cli = manifest.get("diskoInstallCli", "")
        assert cli, "manifest carries no diskoInstallCli path — cannot audit the closure"
        # Resolve the flake to a store path first, exactly as disko-install does.
        # /etc/installer-flake is an environment.etc SYMLINK, and getFlake on a
        # symlink copies the LINK into the store and then cannot read a flake.nix
        # inside it — so auditing that path would audit something disko-install
        # never evaluates.
        flake_path = machine.succeed(
            "nix flake metadata --json /etc/installer-flake | jq -r .path"
        ).strip()
        rc, dry_run = machine.execute(
            "nix-build " + cli + " --dry-run --impure --no-out-link"
            + f" --argstr flake {flake_path}"
            + f" --argstr flakeAttr {host_attr}"
            + f" --argstr rootMountPoint {root_mount_point}"
            + f" --arg writeEfiBootEntries {efi_arg}"
            + f" --arg diskMappings '{{ {disk_name} = \"${diskDevice}\"; }}'"
            + " --argstr extraSystemConfig '{}'"
            + " -A installToplevel -A closureInfo -A diskoScript 2>&1",
            timeout=1800,
        )
        # A dry run that ERRORED is not a dry run that found nothing. Swallowing
        # the status here would make this subtest silently vacuous in exactly the
        # case it exists for — an offline evaluation that could not complete.
        if rc != 0:
            raise Exception(
                "the install evaluation failed OFFLINE, before any disk was touched.\n"
                "Whatever it could not resolve is something the ISO should carry:\n\n"
                + dry_run
            )
        allowed = ${builtins.toJSON rebuildableOnTarget}
        would_build = sorted(set(re.findall(r"/nix/store/\S+\.drv", dry_run)))
        unexpected = [
            d for d in would_build
            if re.sub(r"^/nix/store/[a-z0-9]+-|\.drv$", "", d) not in allowed
        ]
        if unexpected:
            raise Exception(
                "OFFLINE CLOSURE INCOMPLETE — installing on this machine would have to "
                f"build {len(unexpected)} derivation(s) the ISO does not carry and was "
                f"not expected to (allowed: {allowed or 'nothing'}):\n  "
                + "\n  ".join(unexpected)
                + "\n\nFull nix output:\n"
                + dry_run
            )
        if would_build:
            print(f"expected on-target rebuilds ({allowed}): {would_build}")

        # Whether it must be built is one question; whether it CAN be, here, with
        # no network, is the one that decides if the install works. Realise it —
        # disko-install runs this same nix-build as its first step anyway.
        rc, realised = machine.execute(
            "nix-build " + cli + " --impure --no-out-link"
            + f" --argstr flake {flake_path}"
            + f" --argstr flakeAttr {host_attr}"
            + f" --argstr rootMountPoint {root_mount_point}"
            + f" --arg writeEfiBootEntries {efi_arg}"
            + f" --arg diskMappings '{{ {disk_name} = \"${diskDevice}\"; }}'"
            + " --argstr extraSystemConfig '{}'"
            + " -A installToplevel -A closureInfo -A diskoScript 2>&1",
            timeout=1800,
        )
        if rc != 0:
            raise Exception(
                "the install could not be REALISED offline — the ISO carries "
                "neither the outputs nor what it takes to build them:\n\n" + realised
            )

    ${lib.optionalString (answersJson != null) ''
      machine.succeed(
          "cat > /tmp/ih-answers.json <<'IH_EOF'\n"
          + ${builtins.toJSON answersJson}
          + "\nIH_EOF"
      )
    ''}

    # The script ends in `reboot`, and qemu is started with -no-reboot: letting
    # it run would kill the VM before anything could be inspected. Shadow the
    # binary rather than edit the script, so the script under test stays the
    # script that ships.
    machine.succeed(
        "mkdir -p /tmp/ih-stub",
        "printf '#!/bin/sh\\necho STUB-REBOOT\\n' > /tmp/ih-stub/reboot",
        "chmod +x /tmp/ih-stub/reboot",
    )

    with subtest("the offline install completes"):
        # stdin from /dev/null: the unattended script offers a 10-second
        # "press Enter to install now" countdown, and letting it `read` from the
        # driver's shell socket would eat the backdoor protocol.
        machine.succeed(
            "PATH=/tmp/ih-stub:$PATH ${envPrefix} bash ${installScript} </dev/null",
            timeout=${toString installTimeout},
        )

    with subtest("the installed system landed on the disk"):
        # Remount what was just written, using disko's own mountScript rather
        # than `disko-install --mode mount`: that command unmounts again in an
        # EXIT trap, so there would be nothing left to look at by the time it
        # returned. Building the script at all is a third offline proof.
        rc, mount_script = machine.execute(
            "nix-build " + cli + " --impure --no-out-link"
            + f" --argstr flake {flake_path}"
            + f" --argstr flakeAttr {host_attr}"
            + f" --argstr rootMountPoint {root_mount_point}"
            + f" --arg writeEfiBootEntries {efi_arg}"
            + f" --arg diskMappings '{{ {disk_name} = \"${diskDevice}\"; }}'"
            + " --argstr extraSystemConfig '{}' -A mountScript",
            timeout=1800,
        )
        assert rc == 0, f"could not build disko's mountScript offline:\n{mount_script}"
        # nix-build prints the out-path last; anything before it is progress.
        machine.succeed(
            f"mkdir -p {root_mount_point}", mount_script.strip().splitlines()[-1]
        )
        machine.succeed(f"test -e {root_mount_point}/nix/var/nix/db/db.sqlite")
        # The system profile, not /run/current-system: activation runs inside a
        # chroot whose /run is a tmpfs, so that symlink never reaches the disk.
        machine.succeed(f"test -L {root_mount_point}/nix/var/nix/profiles/system")
        # The bootloader is what --write-efi-boot-entries and grub.devices feed,
        # and the divergence they cause is exactly what goes missing first.
        machine.succeed(
            f"test -d {root_mount_point}/boot/EFI || test -d {root_mount_point}/boot/grub"
        )

    ${lib.optionalString (answersJson != null) ''
      with subtest("the technician's answers were seeded for the first boot"):
          primary_root = manifest.get("primaryRoot") or ""
          settings_path = (
              f"{root_mount_point}/etc/nixos/{primary_root}-settings.json"
              if primary_root
              else f"{root_mount_point}/etc/nixos/settings.json"
          )
          seeded = json.loads(machine.succeed(f"cat {settings_path}"))
          expected = json.loads(${builtins.toJSON answersJson})
          for key, want in expected.items():
              node = seeded
              for part in key.split("."):
                  assert part in node, f"{settings_path} has no {key}"
                  node = node[part]
              assert node == want, f"{settings_path}: {key} is {node!r}, expected {want!r}"
          machine.succeed(f"test -e {root_mount_point}/etc/nixos/flake.nix")
          machine.succeed(f"test -e {root_mount_point}/etc/nixos/.first-boot-reconcile")
    ''}

    machine.shutdown()
  '';
}
