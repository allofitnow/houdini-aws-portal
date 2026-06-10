#!/usr/bin/env bash
# generate_test_scene.sh — Create a minimal Houdini Karma test scene (Tester.hiplc).
#
# Purpose: Generates a single-frame Karma render scene for AMI validation.
#          Runs on the build instance (or worker) where Houdini is installed.
#          Produces Tester.hiplc with /out/karma1 that renders a red sphere
#          on a grey background at 256x256, frame 1.
#
# Prerequisites:
#   - Houdini 21.0 installed at /opt/hfs21.0
#   - source /opt/hfs21.0/houdini_setup has been run
#
# Usage:
#   ./generate_test_scene.sh [--output /home/ec2-user/Tester.hiplc]
#
# Output:
#   Tester.hiplc in the specified output directory (default: /home/ec2-user/)

set -euo pipefail

OUTPUT_DIR="/home/ec2-user"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

SCENE_PATH="${OUTPUT_DIR}/Tester.hiplc"

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1
echo "==> [test] generate_test_scene.sh started at $(date)"

# Source Houdini
if [[ -f /opt/hfs21.0/houdini_setup ]]; then
    # shellcheck disable=SC1091
    source /opt/hfs21.0/houdini_setup
else
    echo "FATAL: /opt/hfs21.0/houdini_setup not found"
    exit 1
fi

# Generate the scene via hython
hython << 'PYEOF'
import hou

# Create new hip file
hou.hipFile.clear(suppress_save_prompt=True)

# Create /obj geometry network
obj = hou.node("/obj")
geo = obj.createNode("geo", "test_sphere")

# Inside the geo, delete default file node and add a sphere
geo.deleteItems(geo.children())
sphere = geo.createNode("sphere", "sphere1")
sphere.parm("type").set(2)  # Polygon sphere
sphere.parm("radx").set(1)
sphere.parm("rady").set(1)
sphere.parm("radz").set(1)

# Add a material node
mat = geo.createNode("material", "material1")
mat.setInput(0, sphere)

# Create a simple principled shader
mat_context = hou.node("/mat")
shader = mat_context.createNode("principledshader::2.0", "test_red")
shader.parm("basecolorr").set(0.9)
shader.parm("basecolorg").set(0.1)
shader.parm("basecolorb").set(0.1)

# Assign material
mat.parm("shop_materialpath1").set("/mat/test_red")

# Layout the geo network
geo.layoutChildren()

# Create /out network with a Karma render node
out = hou.node("/out")
karma = out.createNode("karma", "karma1")

# Configure karma render settings
karma.parm("camera").set("/obj/cam1")
karma.parm("resolutionx").set(256)
karma.parm("resolutiony").set(256)
karma.parm("f1").set(1)
karma.parm("f2").set(1)

# Set output path
karma.parm("picture").set("$HIP/renderoutput/Tester.karma1.$F4.exr")

# Create a camera
cam = obj.createNode("cam", "cam1")
cam.parm("tx").set(0)
cam.parm("ty").set(0)
cam.parm("tz").set(5)
cam.parm("lookatpath").set("/obj/test_sphere")

# Create a light
light = obj.createNode("hlight::2.0", "light1")
light.parm("tx").set(3)
light.parm("ty").set(3)
light.parm("tz").set(3)
light.parm("light_intensity").set(1.0)

# Layout all networks
obj.layoutChildren()
out.layoutChildren()

# Save
import os
output_path = os.environ.get("SCENE_OUTPUT", "/home/ec2-user/Tester.hiplc")
hou.hipFile.save(output_path)
print(f"SCENE_SAVED: {output_path}")
PYEOF

if [[ -f "$SCENE_PATH" ]]; then
    echo "==> [test] Test scene created: $SCENE_PATH"
else
    echo "FATAL: Test scene was not created"
    exit 1
fi

echo "==> [test] generate_test_scene.sh completed at $(date)"
