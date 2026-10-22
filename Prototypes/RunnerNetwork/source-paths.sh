# Sourced after repo_root and prototype_dir are set by the build/check scripts.
source "$repo_root/Scripts/prepare-patched-source.sh"
gvproxy_revision=9cfc86f66679ef0feed0f20ba1df558fe2bef5c6
container_version=1.6.0+yieldd
container_revision=ca4884f8f3a13b62c90ea2fb3834f214d61fb91c
gvproxy_source=$(patched_source_directory "$repo_root/.build/network-gvproxy" "$gvproxy_revision" "$prototype_dir/gvproxy.patch")
container_source=$(patched_source_directory "$repo_root/.build/network-container" "$container_revision" "$prototype_dir/container.patch")
relay_module="$repo_root/.build/network-relay.mod"
