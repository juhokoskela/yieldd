# Sourced after repo_root and prototype_dir are set by the build/check scripts.
source "$repo_root/Scripts/prepare-patched-source.sh"
gvproxy_revision=9cfc86f66679ef0feed0f20ba1df558fe2bef5c6
container_revision=a9a62e28f6beb88940122a3d7b286f2d5ae8053a
gvproxy_source=$(patched_source_directory "$repo_root/.build/network-gvproxy" "$gvproxy_revision" "$prototype_dir/gvproxy.patch")
container_source=$(patched_source_directory "$repo_root/.build/network-container" "$container_revision" "$prototype_dir/container.patch")
relay_module="$repo_root/.build/network-relay.mod"
