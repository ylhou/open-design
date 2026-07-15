#!/bin/sh
set -eu

template_dir=/opt/open-design-offline-template/daemon
target_dir=/app/deploy/daemon

if [ ! -d "$template_dir" ]; then
  echo "offline deployment template is missing; load a current offline-builder image" >&2
  exit 1
fi

# Bind mounts hide package-local node_modules from the image. Recreate them
# strictly from the pre-populated store before compiling the changed sources.
pnpm --offline install --frozen-lockfile
pnpm --filter @open-design/daemon... run build
pnpm --filter @open-design/web build

# The template was created by pnpm deploy while the image build had network
# access. Reusing it avoids legacy deploy's registry-metadata resolution path.
rm -rf "$target_dir"
mkdir -p "$(dirname "$target_dir")"
cp -a "$template_dir" "$target_dir"

rm -rf "$target_dir/dist"
cp -a /app/apps/daemon/dist "$target_dir/dist"

# A daemon dependency may also have changed. Sync only workspace packages that
# actually appear in the production deployment and have a compiled dist output.
for package_dir in /app/packages/*; do
  [ -d "$package_dir/dist" ] || continue

  package_name="$(node --input-type=module -e "import { readFileSync } from 'node:fs'; console.log(JSON.parse(readFileSync(process.argv[1], 'utf8')).name)" "$package_dir/package.json")"
  deployed_package="$target_dir/node_modules/$package_name"
  [ -e "$deployed_package" ] || continue

  deployed_dir="$(readlink -f "$deployed_package")"
  rm -rf "$deployed_dir/dist"
  cp -a "$package_dir/dist" "$deployed_dir/dist"
done
