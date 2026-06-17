# B2 Render Workflow

This page describes how to submit a Houdini Karma render job that reads the scene file from Backblaze B2 and writes the rendered frame back to B2. It covers both the reusable helper script and the underlying mechanics, plus the pitfalls found during validation.

---

## Quick start

Use the helper script from the workstation (the Deadline host):

```bash
./aws/submit_b2_render.sh \
  --scene inputs/test-scenes/Tester.hiplc \
  --rop /out/karma1 \
  --group aws-spot-east \
  --timeout 600
```

The script will:

1. Submit a Deadline `CommandLine` job to the specified group.
2. Poll the job until it completes, fails, or times out.
3. Verify the output `.exr` exists in B2 under `outputs/Houdini-Karma-B2-<timestamp>/`.

### Prerequisites

- `deadlinecommand` on PATH.
- The scene file already uploaded to B2 (e.g., `b2://aoin-test/inputs/test-scenes/Tester.hiplc`).
- At least one worker in the target group. SEP can launch a spot worker, or you can launch an on-demand instance manually for validation.
- The worker AMI has rclone configured at `/etc/rclone/rclone.conf` and `/mnt/renders` mounted from B2.

---

## What the job does on the worker

The helper emits a single `CommandLine` task that runs a bash pipeline:

```bash
OUTDIR=/mnt/renders/outputs/<job-name>
mkdir -p "$OUTDIR"
rm -rf /tmp/Tester.hiplc /tmp/renderkarma

# 1. Download input from B2
rclone --config /etc/rclone/rclone.conf copyto \
  b2renders:aoin-test/inputs/test-scenes/Tester.hiplc \
  /tmp/Tester.hiplc

# 2. Redirect the Karma ROP output path to B2
ln -sfn "$OUTDIR" /tmp/renderkarma

# 3. Render frame 1 with hython
/opt/hfs21.0/bin/hython -c '
import hou
hou.hipFile.load("/tmp/Tester.hiplc", suppress_save_prompt=True)
node = hou.node("/out/karma1")
node.render(frame_range=(1, 1))
'

# 4. List the output
find "$OUTDIR" -maxdepth 1 -type f -ls
```

Because `/mnt/renders` is a rclone FUSE mount backed by B2, writing to `$OUTDIR` uploads the frame to B2 in real time.

---

## Why the `/tmp/renderkarma` symlink is required

The test scene's Karma ROP (`/out/karma1`) is configured to write to `/tmp/renderkarma/<scene>.<rop>.####.exr`. If the symlink is not created, the frame is written to the worker's local `/tmp` and is lost when the instance terminates.

Redirecting `/tmp/renderkarma` to `/mnt/renders/outputs/<job-folder>/` makes the ROP write directly to B2 without modifying the scene file. This pattern is preferred over editing the scene file for each job because:

- The same scene can be used for many jobs.
- The output location is determined at job submission time.
- No Houdini license is needed on the submission workstation to edit the scene.

---

## rclone gotchas on workers

| Issue | Cause | Fix |
|---|---|---|
| `Config file "/root/.config/rclone/rclone.conf" not found` | Jobs run as root; rclone defaults to `/root/.config/`. | Use `--config /etc/rclone/rclone.conf`. |
| `directory not found` for `inputs/test-scenes/Tester.hiplc` | rclone interpreted `inputs` as a bucket name. | Include the bucket: `b2renders:aoin-test/inputs/...`. |
| File ends up at `Tester.hiplc/Tester.hiplc` | `rclone copy` treats a file destination as a directory. | Use `rclone copyto` for single files. |
| `/tmp/Tester.hiplc` is a directory from a previous run | Old failed job created `/tmp/Tester.hiplc/` as a directory. | `rm -rf /tmp/Tester.hiplc` before downloading. |

---

## Validated example

The following job was validated end-to-end on 2026-06-17:

- **Job name**: `Houdini-Karma-B2-E2E-v4`
- **Job ID**: `6a32f5bc4908ffb16a694fb8`
- **Worker**: on-demand `g4dn.xlarge` in `us-east-1a` (launched manually for validation)
- **Group**: `aws-spot-east`
- **Input**: `b2://aoin-test/inputs/test-scenes/Tester.hiplc`
- **Output**: `b2://aoin-test/outputs/Houdini-Karma-B2-E2E-v4/Tester.karma1.0001.exr`
- **Result**: Completed successfully.

Spot capacity in `us-east-1` was unavailable during the test (GPU drought), so an on-demand instance was used to isolate the B2 workflow validation from the capacity problem.

---

## Manual submission (without the helper)

If you need to customize the render command beyond what the helper exposes, create a `CommandLine` job info file and plugin info file manually:

```text
# jobinfo.txt
Frames=1
ChunkSize=1
Name=My-B2-Render
Priority=90
Group=aws-spot-east
Pool=none
MachineLimit=0
Plugin=CommandLine
```

```text
# plugininfo.txt
Executable=/bin/bash
Arguments=-c "set -euo pipefail; OUTDIR=/mnt/renders/outputs/My-B2-Render; mkdir -p \"$OUTDIR\"; rm -rf /tmp/Tester.hiplc /tmp/renderkarma; rclone --config /etc/rclone/rclone.conf copyto b2renders:aoin-test/inputs/test-scenes/Tester.hiplc /tmp/Tester.hiplc; ln -sfn \"$OUTDIR\" /tmp/renderkarma; /opt/hfs21.0/bin/hython -c 'import hou; hou.hipFile.load(\"/tmp/Tester.hiplc\", suppress_save_prompt=True); node = hou.node(\"/out/karma1\"); node.render(frame_range=(1, 1))'; find \"$OUTDIR\" -maxdepth 1 -type f -ls"
```

Submit with:

```bash
deadlinecommand -SubmitJob jobinfo.txt plugininfo.txt
```

---

## Future improvements

1. **Move the symlink setup into the AMI or an event plugin.** The `/tmp/renderkarma` symlink and the rclone copy could be handled by worker boot logic or a Deadline event plugin, making job submission a standard Houdini plugin job instead of a custom CommandLine script.
2. **Parameterize the output driver path.** The helper currently hardcodes the assumption that the ROP writes to `/tmp/renderkarma`. A more robust implementation would introspect the scene file to discover the actual output path and redirect it automatically.
3. **Multi-frame support.** The helper renders a single frame (`frame_range=(1, 1)`). For production, set `Frames` in the job info and pass the frame range to `node.render()`.
4. **Spot capacity fallback.** Combine this helper with `aws/scan_gpu_capacity.sh` to pick a group that currently has capacity, or fall back to on-demand when spot is dry.
